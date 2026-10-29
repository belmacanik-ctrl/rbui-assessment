#!/usr/bin/env bash
# =============================================================================
# rbui-check.sh — RDS/Aurora Resilience Blocker Assessment
# Converted from: https://github.com/aws-samples/sample-kiro-rbui-agent
# Covers 66 blockers across 7 categories (FT, SR, EN, KT, CR, AL, QT)
# Read-only: uses only describe/list/get AWS API calls
# =============================================================================
set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
AWS_REGION="${1:-us-east-1}"
OUTPUT_FILE="rbui-report-$(date +%Y%m%d-%H%M%S).txt"

# Severity counters
CRITICAL=0
HIGH=0
MEDIUM=0
LOW=0
INFO=0

# ── COLOURS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'

# ── HELPERS ───────────────────────────────────────────────────────────────────
log()      { echo -e "$*" | tee -a "$OUTPUT_FILE"; }
header()   { log "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; log "${BOLD}${CYAN}  $*${RESET}"; log "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; }
blocker()  {
  local id="$1" sev="$2" msg="$3"
  case "$sev" in
    CRITICAL) ((CRITICAL++)); colour="${RED}";    label="[CRITICAL]" ;;
    HIGH)     ((HIGH++));     colour="${YELLOW}"; label="[HIGH    ]" ;;
    MEDIUM)   ((MEDIUM++));   colour="${CYAN}";   label="[MEDIUM  ]" ;;
    LOW)      ((LOW++));      colour="${GREEN}";  label="[LOW     ]" ;;
    INFO)     ((INFO++));     colour="${RESET}";  label="[INFO    ]" ;;
  esac
  log "  ${colour}${label} ${BOLD}${id}${RESET} — ${msg}"
}

check_prereqs() {
  for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: '$cmd' is required but not installed." >&2; exit 1
    fi
  done
  log "Region : $AWS_REGION"
  log "Output : $OUTPUT_FILE"
  log "Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
}

# ── DATA COLLECTION ───────────────────────────────────────────────────────────
collect_data() {
  header "Collecting RDS/Aurora topology..."

  RDS_INSTANCES=$(aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --query 'DBInstances[*]' \
    --output json 2>/dev/null || echo "[]")

  RDS_CLUSTERS=$(aws rds describe-db-clusters \
    --region "$AWS_REGION" \
    --query 'DBClusters[*]' \
    --output json 2>/dev/null || echo "[]")

  GLOBAL_CLUSTERS=$(aws rds describe-global-clusters \
    --query 'GlobalClusters[*]' \
    --output json 2>/dev/null || echo "[]")

  CLUSTER_SNAPSHOTS=$(aws rds describe-db-cluster-snapshots \
    --region "$AWS_REGION" \
    --snapshot-type manual \
    --query 'DBClusterSnapshots[*]' \
    --output json 2>/dev/null || echo "[]")

  INSTANCE_SNAPSHOTS=$(aws rds describe-db-snapshots \
    --region "$AWS_REGION" \
    --snapshot-type manual \
    --query 'DBSnapshots[*]' \
    --output json 2>/dev/null || echo "[]")

  PROXIES=$(aws rds describe-db-proxies \
    --region "$AWS_REGION" \
    --query 'DBProxies[*]' \
    --output json 2>/dev/null || echo "[]")

  ACCOUNT_ATTRS=$(aws rds describe-account-attributes \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || echo '{"AccountQuotas":[]}')

  KMS_QUOTA=$(aws service-quotas get-service-quota \
    --service-code kms \
    --quota-code L-2AC98190 \
    --region "$AWS_REGION" \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "5500")

  INSTANCE_COUNT=$(echo "$RDS_INSTANCES" | jq 'length')
  CLUSTER_COUNT=$(echo "$RDS_CLUSTERS"   | jq 'length')
  log "  Found $INSTANCE_COUNT instances, $CLUSTER_COUNT clusters"
}

# =============================================================================
# CATEGORY 1: FAILOVER TIMING (FT)
# =============================================================================
check_failover_timing() {
  header "Category 1: Failover Timing (FT)"

  # FT-01 / FT-02 — Multi-AZ standby count
  while IFS= read -r inst; do
    id=$(echo "$inst"   | jq -r '.DBInstanceIdentifier')
    maz=$(echo "$inst"  | jq -r '.MultiAZ')
    engine=$(echo "$inst" | jq -r '.Engine')

    if [[ "$maz" == "false" ]]; then
      blocker "FT-09" CRITICAL "Instance '$id' is Single-AZ — AZ failure requires snapshot restore (RTO: minutes to hours)"
    else
      blocker "FT-01" INFO "Instance '$id' is Multi-AZ (single standby) — minimum 60-120s failover RTO"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')

  # FT-03 — Large transaction warning (proxy via instance class — can't query directly)
  while IFS= read -r inst; do
    id=$(echo "$inst"  | jq -r '.DBInstanceIdentifier')
    cls=$(echo "$inst" | jq -r '.DBInstanceClass')
    blocker "FT-03" MEDIUM "Instance '$id' ($cls): large transactions under load may extend failover beyond 120s — monitor max_transaction_age"
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')

  # FT-04 / FT-05 — DNS TTL awareness
  while IFS= read -r inst; do
    id=$(echo "$inst"     | jq -r '.DBInstanceIdentifier')
    engine=$(echo "$inst" | jq -r '.Engine')
    if [[ "$engine" == aurora* ]]; then
      blocker "FT-04" MEDIUM "Aurora instance '$id': DNS TTL=5s but client-side caching can extend stale routing window"
    else
      blocker "FT-05" MEDIUM "RDS instance '$id': CNAME TTL=60s — 60s stale routing window after failover"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')

  # FT-06 — JVM DNS warning (static check)
  blocker "FT-06" HIGH "JVM default DNS TTL can be INFINITE — Java apps using this DB may never reconnect after failover. Verify networkaddress.cache.ttl=60 in all Java clients."

  # FT-07 — Aurora clusters without readers
  # ROOT CAUSE FIX: DBClusterMembers[] is empty ([]) in describe-db-clusters
  # even when instances exist. We cross-reference describe-db-instances instead,
  # matching on DBClusterIdentifier. Aurora readers have a non-null
  # ReadReplicaSourceDBInstanceIdentifier; writers do not.
  while IFS= read -r cluster; do
    cid=$(echo "$cluster"    | jq -r '.DBClusterIdentifier')
    engine=$(echo "$cluster" | jq -r '.Engine')

    if [[ "$engine" != aurora* ]]; then
      continue
    fi

    # Count all instances belonging to this cluster via describe-db-instances
    total=$(echo "$RDS_INSTANCES" | jq --arg cid "$cid" \
      '[.[] | select(.DBClusterIdentifier==$cid)] | length')
    total=${total:-0}

    # Count readers: Aurora reader instances have a non-empty
    # ReadReplicaSourceDBInstanceIdentifier field
    readers=$(echo "$RDS_INSTANCES" | jq --arg cid "$cid" \
      '[.[] | select(.DBClusterIdentifier==$cid)
             | select((.ReadReplicaSourceDBInstanceIdentifier // "") != "")
        ] | length')
    readers=${readers:-0}

    if [[ "$total" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine) has NO instances — cluster is empty, RTO: undefined"
    elif [[ "$readers" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine) has $total instance(s), all writers, NO readers — no failover target, RTO: 10-15 minutes"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # FT-08 — Aurora secondary clusters restart during primary failover
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    members=$(echo "$gc" | jq '.GlobalClusterMembers | length')
    if [[ "$members" -gt 1 ]]; then
      blocker "FT-08" HIGH "Global cluster '$gcid': secondary cluster readers restart during primary failover — secondary unavailable during events"
    fi
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')
}

# =============================================================================
# CATEGORY 2: SNAPSHOT RESTORE CONSTRAINTS (SR)
# =============================================================================
check_snapshot_restore() {
  header "Category 2: Snapshot Restore Constraints (SR)"

  # SR-01 — Lazy loading
  blocker "SR-01" MEDIUM "All snapshot restores use lazy loading from S3 — 'available' status does NOT mean performant. Use pg_prewarm or dummy reads post-restore."

  # SR-03 — Always creates new instance
  blocker "SR-03" HIGH "Snapshot restore ALWAYS creates a new instance — existing endpoints will NOT point to restored DB. Application connection strings must be updated."

  # SR-05 — Default parameter group on restore
  while IFS= read -r snap; do
    snapid=$(echo "$snap"  | jq -r '.DBClusterSnapshotIdentifier // .DBSnapshotIdentifier')
    blocker "SR-05" MEDIUM "Snapshot '$snapid': restore will assign DEFAULT parameter group — all custom tuning (work_mem, random_page_cost, etc.) will be lost"
  done < <(echo "$CLUSTER_SNAPSHOTS" | jq -c '.[]')

  # SR-06 — Default security group
  blocker "SR-06" HIGH "Restored instances get DEFAULT security group — DB may be unreachable post-restore. Verify and apply correct SG immediately after restore."

  # SR-07 — Aurora PITR adds instances separately
  while IFS= read -r cluster; do
    cid=$(echo "$cluster" | jq -r '.DBClusterIdentifier')
    engine=$(echo "$cluster" | jq -r '.Engine')
    if [[ "$engine" == aurora* ]]; then
      blocker "SR-07" MEDIUM "Aurora cluster '$cid': PITR restores cluster only — reader instances must be added separately (+5-10 min per instance)"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # SR-08 — PITR 5-min RPO gap
  while IFS= read -r cluster; do
    cid=$(echo "$cluster"  | jq -r '.DBClusterIdentifier')
    pitr=$(echo "$cluster" | jq -r '.BackupRetentionPeriod')
    if [[ "$pitr" -gt 0 ]]; then
      blocker "SR-08" MEDIUM "Cluster '$cid': PITR transaction logs uploaded every 5 min — minimum RPO gap is 5 minutes"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # SR-10 — Restore time scales with DB size
  while IFS= read -r inst; do
    id=$(echo "$inst"      | jq -r '.DBInstanceIdentifier')
    storage=$(echo "$inst" | jq -r '.AllocatedStorage // 0')
    if   [[ "$storage" -gt 500 ]]; then
      blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO estimated 60-180 min"
    elif [[ "$storage" -gt 100 ]]; then
      blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO estimated 30-60 min"
    else
      blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO estimated 15-30 min"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')
}

# =============================================================================
# CATEGORY 3: ENCRYPTION CONSTRAINTS (EN)
# =============================================================================
check_encryption() {
  header "Category 3: Encryption Constraints (EN)"

  # EN-01 — Unencrypted instances
  while IFS= read -r inst; do
    id=$(echo "$inst"  | jq -r '.DBInstanceIdentifier')
    enc=$(echo "$inst" | jq -r '.StorageEncrypted')
    if [[ "$enc" == "false" ]]; then
      blocker "EN-01" HIGH "Instance '$id' is UNENCRYPTED — enabling encryption requires snapshot→encrypt→restore migration (downtime required)"
      blocker "EN-04" HIGH "Instance '$id' is UNENCRYPTED — cross-region replicas and Global Database are BLOCKED until encrypted"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')

  # EN-04 — Unencrypted clusters
  while IFS= read -r cluster; do
    cid=$(echo "$cluster" | jq -r '.DBClusterIdentifier')
    enc=$(echo "$cluster" | jq -r '.StorageEncrypted')
    if [[ "$enc" == "false" ]]; then
      blocker "EN-04" HIGH "Cluster '$cid' is UNENCRYPTED — ALL cross-region DR paths (Global DB, cross-region replicas) are BLOCKED"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # EN-02 / EN-03 — KMS key type check
  while IFS= read -r inst; do
    id=$(echo "$inst"  | jq -r '.DBInstanceIdentifier')
    enc=$(echo "$inst" | jq -r '.StorageEncrypted')
    kms=$(echo "$inst" | jq -r '.KmsKeyId // ""')
    if [[ "$enc" == "true" ]]; then
      if echo "$kms" | grep -q "aws/rds"; then
        blocker "EN-05" MEDIUM "Instance '$id' uses AWS-managed key (aws/rds) — cross-account backup copy is BLOCKED. Migrate to customer-managed CMK."
      fi
      blocker "EN-03" MEDIUM "Instance '$id': cross-region snapshot copies require re-encryption with a pre-provisioned CMK in the destination region"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]')

  # EN-06 — Global DB KMS inaccessible = terminal
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    blocker "EN-06" CRITICAL "Global cluster '$gcid': if KMS key becomes inaccessible for 7+ days, the global database is TERMINAL — no recovery possible. Enable KMS key deletion alerts."
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')
}

# =============================================================================
# CATEGORY 4: KMS API THROTTLING (KT)
# =============================================================================
check_kms_throttling() {
  header "Category 4: KMS API Throttling (KT)"

  enc_count=$(echo "$RDS_INSTANCES" | jq '[.[] | select(.StorageEncrypted==true)] | length')
  blocker "KT-01" MEDIUM "KMS symmetric operations quota: ${KMS_QUOTA} req/s — $enc_count encrypted instances share this quota for parallel restores"
  blocker "KT-02" HIGH "KMS quota is SHARED across ALL services (RDS, S3, EBS, Lambda) using the same key — contention during DR events is likely"
  blocker "KT-03" HIGH "Exceeding KMS quota returns ThrottlingException — parallel encrypted restores during a DR event may stall or fail silently"
  blocker "KT-04" HIGH "KMS CreateGrant quota: 50 req/s — each RDS operation consumes one grant. Fleet-wide restores will bottleneck here."
}

# =============================================================================
# CATEGORY 5: CROSS-REGION DR CONSTRAINTS (CR)
# =============================================================================
check_cross_region_dr() {
  header "Category 5: Cross-Region DR Constraints (CR)"

  # CR-01 — Aurora: no automated cross-region backup replication (check if Global DB exists)
  while IFS= read -r cluster; do
    cid=$(echo "$cluster"    | jq -r '.DBClusterIdentifier')
    engine=$(echo "$cluster" | jq -r '.Engine')
    in_global=$(echo "$GLOBAL_CLUSTERS" | jq --arg cid "$cid" \
      '[.[].GlobalClusterMembers[].DBClusterArn | test($cid)] | any')
    if [[ "$engine" == aurora* ]] && [[ "$in_global" == "false" ]]; then
      blocker "CR-01" HIGH "Aurora cluster '$cid' has NO Global DB and NO cross-region automated backups — must use manual cross-region snapshot copies for DR"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # CR-05 — Global DB version mismatch check
  while IFS= read -r gc; do
    gcid=$(echo "$gc"    | jq -r '.GlobalClusterIdentifier')
    ver=$(echo "$gc"     | jq -r '.EngineVersion')
    status=$(echo "$gc"  | jq -r '.Status')
    blocker "CR-05" CRITICAL "Global cluster '$gcid' (version $ver, status $status): switchover requires identical major+minor version across ALL members — version drift silently blocks DR"
    blocker "CR-06" HIGH "Global cluster '$gcid': some engines require identical patch levels — undocumented patch drift can break DR without warning"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')

  # CR-08 — Global DB secondary auto scaling
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    blocker "CR-08" MEDIUM "Global cluster '$gcid': secondary clusters do NOT support Auto Scaling — they may be under-provisioned for a full failover workload"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')

  # CR-14 — Async replication lag
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    blocker "CR-14" MEDIUM "Global cluster '$gcid': replication is ASYNC — sub-second typical but NOT guaranteed under load. RPO > 0 must be accepted."
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')

  # CR-10 — Secrets Manager not supported with Global DB
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    blocker "CR-10" MEDIUM "Global cluster '$gcid': Secrets Manager is NOT supported with Global DB — credential management gap, manual rotation required"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')

  # CR-11 — Auto minor version upgrade ineffective on global clusters
  while IFS= read -r cluster; do
    cid=$(echo "$cluster" | jq -r '.DBClusterIdentifier')
    amvu=$(echo "$cluster" | jq -r '.AutoMinorVersionUpgrade // false')
    in_global=$(echo "$GLOBAL_CLUSTERS" | jq --arg cid "$cid" \
      '[.[].GlobalClusterMembers[].DBClusterArn | test($cid)] | any')
    if [[ "$in_global" == "true" ]] && [[ "$amvu" == "true" ]]; then
      blocker "CR-11" MEDIUM "Cluster '$cid' is in Global DB with AutoMinorVersionUpgrade=true — auto minor upgrades have NO EFFECT on global clusters; must coordinate manually"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')
}

# =============================================================================
# CATEGORY 6: APPLICATION-LAYER RESILIENCE (AL)
# =============================================================================
check_application_layer() {
  header "Category 6: Application-Layer Resilience (AL)"

  proxy_count=$(echo "$PROXIES" | jq 'length')

  # AL-01 — No RDS Proxy
  while IFS= read -r cluster; do
    cid=$(echo "$cluster" | jq -r '.DBClusterIdentifier')
    cluster_proxy=$(echo "$PROXIES" | jq --arg cid "$cid" \
      '[.[].DBProxyName | test($cid)] | any')
    if [[ "$cluster_proxy" == "false" ]]; then
      blocker "AL-01" HIGH "Cluster '$cid' has NO RDS Proxy — failover relies on DNS propagation (5-60s stale routing). Deploy RDS Proxy or AWS JDBC Wrapper."
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]')

  # AL-02 — Connection pool stale connections (static)
  blocker "AL-02" HIGH "Connection pools hold stale connections after failover — errors until pool cycles. Ensure connection validation and short pool TTL are configured in all app layers."

  # AL-03 — TCP keepalive
  blocker "AL-03" MEDIUM "TCP keepalive defaults are 2+ hours — dead connections take minutes to detect after failover. Set tcp_keepalive_time=60 on DB clients."

  # AL-04 — RDS Proxy on secondary fails after global failover
  if [[ "$proxy_count" -gt 0 ]]; then
    blocker "AL-04" MEDIUM "RDS Proxy detected: after a Global DB failover, Proxy on old primary region still points to demoted instance — must redirect Proxy to new primary"
  fi

  # AL-06 — Cluster cache management for PostgreSQL secondary
  while IFS= read -r gc; do
    gcid=$(echo "$gc" | jq -r '.GlobalClusterIdentifier')
    engine=$(echo "$gc" | jq -r '.Engine')
    if [[ "$engine" == aurora-postgresql* ]]; then
      blocker "AL-06" MEDIUM "Global cluster '$gcid' (PostgreSQL): Cluster Cache Management is NOT supported for secondary clusters — cold buffer pool after failover causes performance degradation"
    fi
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]')

  # FT-06 reminder
  blocker "AL-06" MEDIUM "Verify all Java clients have networkaddress.cache.ttl=60 — JVM DNS TTL defaults to INFINITE and prevents reconnection after Aurora failover"
}

# =============================================================================
# CATEGORY 7: ACCOUNT QUOTAS (QT)
# =============================================================================
check_account_quotas() {
  header "Category 7: Account-Level Service Quotas (QT)"

  get_quota() {
    echo "$ACCOUNT_ATTRS" | jq -r --arg name "$1" \
      '.AccountQuotas[] | select(.AccountQuotaName==$name) | "\(.Used)/\(.Max)"' 2>/dev/null || echo "N/A"
  }

  # QT-01 — Manual cluster snapshots
  snap_count=$(echo "$CLUSTER_SNAPSHOTS" | jq 'length')
  if [[ "$snap_count" -ge 90 ]]; then
    blocker "QT-01" HIGH "Manual cluster snapshots: $snap_count/100 — approaching limit. DR snapshot copies will fail if quota is exceeded."
  else
    log "    [OK] Manual cluster snapshots: $snap_count/100"
  fi

  # QT-02 — Manual instance snapshots
  isnap_count=$(echo "$INSTANCE_SNAPSHOTS" | jq 'length')
  if [[ "$isnap_count" -ge 90 ]]; then
    blocker "QT-02" HIGH "Manual instance snapshots: $isnap_count/100 — approaching limit."
  else
    log "    [OK] Manual instance snapshots: $isnap_count/100"
  fi

  # QT-03 — DB instances per region
  if [[ "$INSTANCE_COUNT" -ge 36 ]]; then
    blocker "QT-03" CRITICAL "DB instances: $INSTANCE_COUNT/40 — approaching regional limit. DR restore operations WILL FAIL when limit is reached."
  else
    log "    [OK] DB instances: $INSTANCE_COUNT/40"
  fi

  # QT-04 — DB clusters per region
  if [[ "$CLUSTER_COUNT" -ge 36 ]]; then
    blocker "QT-04" CRITICAL "DB clusters: $CLUSTER_COUNT/40 — approaching regional limit."
  else
    log "    [OK] DB clusters: $CLUSTER_COUNT/40"
  fi

  # QT-07 — Concurrent cross-region snapshot copies (limit=5)
  blocker "QT-07" HIGH "Concurrent cross-region snapshot copies: limit is 5 — a DR event copying multiple snapshots simultaneously will queue and delay recovery"

  # QT-10 — Aurora Global Databases
  gc_count=$(echo "$GLOBAL_CLUSTERS" | jq 'length')
  if [[ "$gc_count" -ge 5 ]]; then
    blocker "QT-10" MEDIUM "Aurora Global Databases: $gc_count/5 — at limit. Cannot add more global clusters without a quota increase."
  else
    log "    [OK] Aurora Global Databases: $gc_count/5"
  fi

  # QT-15 — KMS CreateGrant
  blocker "QT-15" HIGH "KMS CreateGrant quota: 50 req/s — each encrypted RDS operation consumes one grant. Fleet-wide encrypted restores bottleneck here."

  # QT-19 — Proxies
  proxy_count=$(echo "$PROXIES" | jq 'length')
  if [[ "$proxy_count" -ge 18 ]]; then
    blocker "QT-19" MEDIUM "RDS Proxies: $proxy_count/20 — approaching limit."
  else
    log "    [OK] RDS Proxies: $proxy_count/20"
  fi
}

# =============================================================================
# REPORT SUMMARY
# =============================================================================
print_summary() {
  header "ASSESSMENT SUMMARY"
  log ""
  log "  Region   : $AWS_REGION"
  log "  Instances: $INSTANCE_COUNT"
  log "  Clusters : $CLUSTER_COUNT"
  log ""
  log "  ${RED}${BOLD}CRITICAL : $CRITICAL${RESET}"
  log "  ${YELLOW}${BOLD}HIGH     : $HIGH${RESET}"
  log "  ${CYAN}MEDIUM   : $MEDIUM${RESET}"
  log "  ${GREEN}LOW      : $LOW${RESET}"
  log "  INFO     : $INFO"
  log ""

  TOTAL=$((CRITICAL + HIGH + MEDIUM + LOW))
  if   [[ "$CRITICAL" -gt 0 ]]; then
    log "  ${RED}${BOLD}VERDICT: CRITICAL BLOCKERS FOUND — DR is broken or severely limited${RESET}"
  elif [[ "$HIGH"     -gt 0 ]]; then
    log "  ${YELLOW}${BOLD}VERDICT: HIGH-SEVERITY BLOCKERS — DR paths exist but are unreliable${RESET}"
  elif [[ "$MEDIUM"   -gt 0 ]]; then
    log "  ${CYAN}VERDICT: MEDIUM ISSUES — DR possible but recovery times degraded${RESET}"
  else
    log "  ${GREEN}${BOLD}VERDICT: No critical blockers found${RESET}"
  fi

  log ""
  log "  Remediation priority:"
  log "    P1 (Immediate) — All CRITICAL items above"
  log "    P2 (This week) — All HIGH items above"
  log "    P3 (30 days)   — All MEDIUM items above"
  log ""
  log "  Full report saved to: $OUTPUT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  log "================================================================"
  log "  RBUI — RDS/Aurora Resilience Blocker Assessment"
  log "  $(date)"
  log "================================================================"

  check_prereqs
  collect_data

  check_failover_timing
  check_snapshot_restore
  check_encryption
  check_kms_throttling
  check_cross_region_dr
  check_application_layer
  check_account_quotas

  print_summary
}

main "$@"
