#!/usr/bin/env bash
# =============================================================================
# rbui-check.sh — RDS/Aurora Resilience Blocker Assessment v1.1.0
# Converted from: https://github.com/aws-samples/sample-kiro-rbui-agent
# Output: HTML report (rbui-report-YYYYMMDD-HHMMSS.html)
# Read-only: uses only describe/list/get AWS API calls
# =============================================================================

# NOTE: Do NOT use set -e — arithmetic like VAR=$((VAR+1)) is safe but
# the older ((VAR++)) form returns exit 1 when VAR=0 under set -e.
set -uo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
AWS_REGION="${1:-us-east-1}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_HTML="rbui-report-${TIMESTAMP}.html"

# Severity counters
CRITICAL=0; HIGH=0; MEDIUM=0; LOW=0; INFO_COUNT=0

# Terminal colours
RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'

# Section state for HTML
_SECTION_OPEN=0

# =============================================================================
# HTML WRITER
# =============================================================================
html_init() {
  cat > "$OUTPUT_HTML" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>RBUI — RDS/Aurora Resilience Assessment</title>
<style>
:root{--c:#c0392b;--cb:#fdf2f2;--h:#d35400;--hb:#fef6f0;
      --m:#2980b9;--mb:#f0f8ff;--l:#27ae60;--lb:#f0fff4;
      --i:#555;--ib:#fafafa;--hdr:#1a2b45;}
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
     background:#f4f6f9;color:#2c3e50;font-size:14px;padding:20px;}
h1{color:#fff;background:var(--hdr);padding:20px 24px;
   border-radius:8px 8px 0 0;font-size:1.4em;}
.meta{background:#253555;color:#cdd6e0;padding:10px 24px;
      font-size:.85em;border-radius:0 0 8px 8px;margin-bottom:20px;}
.toc{background:#fff;border-radius:8px;padding:14px 20px;
     margin-bottom:16px;box-shadow:0 1px 4px rgba(0,0,0,.08);}
.toc h3{margin-bottom:8px;color:#777;font-size:.8em;text-transform:uppercase;}
.toc a{color:#2980b9;text-decoration:none;margin-right:12px;font-size:.88em;}
.section{background:#fff;border-radius:8px;margin-bottom:16px;
         box-shadow:0 1px 4px rgba(0,0,0,.08);overflow:hidden;}
.sh{background:var(--hdr);color:#fff;padding:10px 16px;
    font-weight:600;font-size:.95em;}
table{width:100%;border-collapse:collapse;}
th{background:#ecf0f1;padding:8px 12px;text-align:left;
   font-size:.78em;text-transform:uppercase;color:#7f8c8d;
   border-bottom:2px solid #ddd;}
td{padding:9px 12px;border-bottom:1px solid #f0f0f0;
   vertical-align:top;line-height:1.5;}
tr:last-child td{border-bottom:none;}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;
       font-weight:700;font-size:.75em;letter-spacing:.03em;}
.CRITICAL{color:var(--c);background:var(--cb);}
.HIGH    {color:var(--h);background:var(--hb);}
.MEDIUM  {color:var(--m);background:var(--mb);}
.LOW     {color:var(--l);background:var(--lb);}
.INFO    {color:var(--i);background:var(--ib);}
.OK      {color:var(--l);background:var(--lb);}
tr.CRITICAL td{background:var(--cb);}
tr.HIGH     td{background:var(--hb);}
tr.MEDIUM   td{background:var(--mb);}
.idc{font-family:monospace;font-weight:700;white-space:nowrap;}
.scores{display:flex;gap:12px;flex-wrap:wrap;padding:16px;}
.sb{flex:1;min-width:90px;border-radius:8px;padding:14px;
    text-align:center;font-weight:700;font-size:1.5em;}
.sb span{display:block;font-size:.5em;font-weight:400;
         text-transform:uppercase;margin-top:4px;}
.sc{color:var(--c);background:var(--cb);}
.sh2{color:var(--h);background:var(--hb);}
.sm{color:var(--m);background:var(--mb);}
.sl{color:var(--l);background:var(--lb);}
.si{color:var(--i);background:var(--ib);}
.verdict{margin:0 16px 16px;padding:12px 16px;border-radius:6px;
         font-weight:600;font-size:.95em;}
.vc{background:var(--cb);color:var(--c);border-left:4px solid var(--c);}
.vh{background:var(--hb);color:var(--h);border-left:4px solid var(--h);}
.vm{background:var(--mb);color:var(--m);border-left:4px solid var(--m);}
.vok{background:var(--lb);color:var(--l);border-left:4px solid var(--l);}
footer{text-align:center;color:#aaa;font-size:.78em;margin-top:20px;}
</style></head><body>
HTMLHEAD
}

html_meta() {
  printf '<h1>&#x1F6E1; RBUI &mdash; RDS/Aurora Resilience Blocker Assessment</h1>\n' >> "$OUTPUT_HTML"
  printf '<div class="meta">Account: <strong>%s</strong> &nbsp;|&nbsp; Region: <strong>%s</strong> &nbsp;|&nbsp; Generated: <strong>%s</strong></div>\n' \
    "$1" "$AWS_REGION" "$(date)" >> "$OUTPUT_HTML"
}

html_toc() {
  cat >> "$OUTPUT_HTML" << 'TOCHML'
<div class="toc"><h3>Jump to section</h3>
<a href="#summary">Summary</a>
<a href="#ft">Failover Timing</a>
<a href="#sr">Snapshot Restore</a>
<a href="#en">Encryption</a>
<a href="#kt">KMS Throttling</a>
<a href="#cr">Cross-Region DR</a>
<a href="#al">App Layer</a>
<a href="#qt">Quotas</a>
</div>
TOCHML
}

html_section_open() {
  local id="$1" title="$2"
  if [[ "$_SECTION_OPEN" -eq 1 ]]; then
    echo '</table></div>' >> "$OUTPUT_HTML"
  fi
  _SECTION_OPEN=1
  printf '<div class="section" id="%s">\n<div class="sh">%s</div>\n<table>\n<tr><th style="width:90px">Severity</th><th style="width:80px">ID</th><th>Finding</th></tr>\n' \
    "$id" "$title" >> "$OUTPUT_HTML"
}

html_row() {
  local sev="$1" id="$2" msg="$3"
  local emsg
  emsg=$(printf '%s' "$msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  printf '<tr class="%s"><td><span class="badge %s">%s</span></td><td class="idc">%s</td><td>%s</td></tr>\n' \
    "$sev" "$sev" "$sev" "$id" "$emsg" >> "$OUTPUT_HTML"
}

html_ok_row() {
  local msg="$1"
  local emsg
  emsg=$(printf '%s' "$msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  printf '<tr><td><span class="badge OK">OK</span></td><td class="idc">&mdash;</td><td>%s</td></tr>\n' \
    "$emsg" >> "$OUTPUT_HTML"
}

html_summary() {
  local c="$1" h="$2" m="$3" l="$4" i="$5"
  local vcls vtxt
  if   [[ "$c" -gt 0 ]]; then vcls="vc";  vtxt="&#x26A0; CRITICAL BLOCKERS FOUND — DR is broken or severely limited. Address P1 items immediately."
  elif [[ "$h" -gt 0 ]]; then vcls="vh";  vtxt="&#x26A0; HIGH-SEVERITY BLOCKERS — DR paths exist but are unreliable. Address P2 items this week."
  elif [[ "$m" -gt 0 ]]; then vcls="vm";  vtxt="&#x26A0; MEDIUM ISSUES — DR is possible but recovery times degraded. Address within 30 days."
  else                         vcls="vok"; vtxt="&#x2705; No critical blockers found — review INFO items for best-practice improvements."
  fi

  if [[ "$_SECTION_OPEN" -eq 1 ]]; then
    echo '</table></div>' >> "$OUTPUT_HTML"
    _SECTION_OPEN=0
  fi

  cat >> "$OUTPUT_HTML" << SUMHTML
<div class="section" id="summary">
<div class="sh">Assessment Summary</div>
<div class="scores">
  <div class="sb sc">$c<span>Critical</span></div>
  <div class="sb sh2">$h<span>High</span></div>
  <div class="sb sm">$m<span>Medium</span></div>
  <div class="sb sl">$l<span>Low</span></div>
  <div class="sb si">$i<span>Info</span></div>
</div>
<div class="verdict $vcls">$vtxt</div>
<table>
<tr><th>Priority</th><th>When</th><th>Focus</th></tr>
<tr><td><strong>P1 &mdash; Immediate</strong></td><td>Today</td><td>All CRITICAL items</td></tr>
<tr><td><strong>P2 &mdash; This week</strong></td><td>1&ndash;7 days</td><td>All HIGH items</td></tr>
<tr><td><strong>P3 &mdash; 30 days</strong></td><td>This month</td><td>All MEDIUM items</td></tr>
</table></div>
SUMHTML
}

html_close() {
  printf '<footer>RBUI v1.1.0 &nbsp;|&nbsp; Read-only assessment &nbsp;|&nbsp; Based on <a href="https://github.com/aws-samples/sample-kiro-rbui-agent">aws-samples/sample-kiro-rbui-agent</a></footer>\n</body></html>\n' >> "$OUTPUT_HTML"
}

# =============================================================================
# CORE HELPERS
# =============================================================================
log() { echo -e "$*"; }

header() {
  log ""
  log "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
  log "${BOLD}${CYAN}  $*${RESET}"
  log "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
}

blocker() {
  local id="$1" sev="$2" msg="$3"
  local colour label
  case "$sev" in
    CRITICAL) CRITICAL=$((CRITICAL+1));     colour="${RED}";    label="[CRITICAL]" ;;
    HIGH)     HIGH=$((HIGH+1));             colour="${YELLOW}"; label="[HIGH    ]" ;;
    MEDIUM)   MEDIUM=$((MEDIUM+1));         colour="${CYAN}";   label="[MEDIUM  ]" ;;
    LOW)      LOW=$((LOW+1));               colour="${GREEN}";  label="[LOW     ]" ;;
    INFO)     INFO_COUNT=$((INFO_COUNT+1)); colour="${RESET}";  label="[INFO    ]" ;;
  esac
  log "  ${colour}${label} ${BOLD}${id}${RESET} -- ${msg}"
  html_row "$sev" "$id" "$msg"
}

ok() {
  log "    ${GREEN}[OK]${RESET} $*"
  html_ok_row "$*"
}

jqr() { echo "$1" | jq -r "${@:2}" 2>/dev/null || echo ""; }

# =============================================================================
# PREREQUISITES
# =============================================================================
check_prereqs() {
  for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: '$cmd' is required but not installed." >&2; exit 1
    fi
  done
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
  log "Account : $acct"
  log "Region  : $AWS_REGION"
  log "Report  : $OUTPUT_HTML"
  if [[ "$acct" == "UNKNOWN" ]]; then
    echo "ERROR: AWS credentials invalid. Run 'aws sts get-caller-identity'." >&2; exit 1
  fi
  echo "$acct"
}

# =============================================================================
# DATA COLLECTION
# =============================================================================
collect_data() {
  html_section_open "collect" "Data Collection"
  header "Collecting RDS/Aurora topology..."

  _aws() {
    local label="$1"; shift
    local out
    out=$(aws "$@" --output json 2>/tmp/rbui_err) || {
      local err; err=$(cat /tmp/rbui_err | head -1)
      log "  ${YELLOW}[WARN]${RESET} $label failed: $err"
      html_row "HIGH" "API" "$label failed: $err"
      echo "[]"; return
    }
    echo "$out"
  }

  RDS_INSTANCES=$(_aws "describe-db-instances"     rds describe-db-instances     --region "$AWS_REGION" --query 'DBInstances[*]')
  RDS_CLUSTERS=$(_aws  "describe-db-clusters"      rds describe-db-clusters      --region "$AWS_REGION" --query 'DBClusters[*]')
  GLOBAL_CLUSTERS=$(_aws "describe-global-clusters" rds describe-global-clusters --query 'GlobalClusters[*]')
  CLUSTER_SNAPSHOTS=$(_aws "describe-db-cluster-snapshots" rds describe-db-cluster-snapshots --region "$AWS_REGION" --snapshot-type manual --query 'DBClusterSnapshots[*]')
  INSTANCE_SNAPSHOTS=$(_aws "describe-db-snapshots"  rds describe-db-snapshots   --region "$AWS_REGION" --snapshot-type manual --query 'DBSnapshots[*]')
  PROXIES=$(_aws "describe-db-proxies"               rds describe-db-proxies     --region "$AWS_REGION" --query 'DBProxies[*]')
  ACCOUNT_ATTRS=$(_aws "describe-account-attributes" rds describe-account-attributes --region "$AWS_REGION")
  echo "$ACCOUNT_ATTRS" | jq -e 'type == "array"' &>/dev/null && ACCOUNT_ATTRS='{"AccountQuotas":[]}'

  KMS_QUOTA=$(aws service-quotas get-service-quota \
    --service-code kms --quota-code L-2AC98190 \
    --region "$AWS_REGION" --query 'Quota.Value' --output text 2>/dev/null || echo "5500")

  INSTANCE_COUNT=$(echo "$RDS_INSTANCES" | jq 'length' 2>/dev/null || echo 0)
  CLUSTER_COUNT=$(echo  "$RDS_CLUSTERS"  | jq 'length' 2>/dev/null || echo 0)
  local msg="Found $INSTANCE_COUNT instances, $CLUSTER_COUNT clusters in $AWS_REGION"
  log "  $msg"
  html_ok_row "$msg"
}

# =============================================================================
# CATEGORY 1: FAILOVER TIMING (FT)
# =============================================================================
check_failover_timing() {
  html_section_open "ft" "Category 1: Failover Timing (FT)"
  header "Category 1: Failover Timing (FT)"

  while IFS= read -r inst; do
    local id engine maz
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    engine=$(jqr "$inst" -r '.Engine')
    maz=$(jqr "$inst" -r '.MultiAZ')
    if [[ "$engine" != aurora* ]]; then
      if [[ "$maz" == "false" ]]; then
        blocker "FT-09" CRITICAL "RDS instance '$id' ($engine) is Single-AZ -- AZ failure requires snapshot restore (RTO: minutes to hours)"
      else
        blocker "FT-01" INFO "RDS instance '$id' ($engine) is Multi-AZ -- minimum 60-120s failover RTO"
      fi
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r inst; do
    local id cls
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    cls=$(jqr "$inst" -r '.DBInstanceClass')
    blocker "FT-03" MEDIUM "Instance '$id' ($cls): large open transactions extend failover beyond 120s -- monitor long-running transactions"
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r inst; do
    local id engine
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    engine=$(jqr "$inst" -r '.Engine')
    if [[ "$engine" == aurora* ]]; then
      blocker "FT-04" MEDIUM "Aurora instance '$id': DNS TTL=5s but client-side caching can extend stale routing window"
    else
      blocker "FT-05" MEDIUM "RDS instance '$id': CNAME TTL=60s -- 60s stale routing window after failover"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)

  blocker "FT-06" HIGH "JVM DNS TTL defaults to INFINITE -- Java apps may never reconnect after Aurora failover. Set networkaddress.cache.ttl=60 in java.security."

  # FT-07: Two-stage reader detection
  # Stage 1: use DBClusterMembers if non-empty (IsClusterWriter is reliable)
  # Stage 2: fall back to describe-db-instances cross-reference
  while IFS= read -r cluster; do
    local cid engine members_len readers total writers
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');    [[ -z "$cid" ]]  && continue
    engine=$(jqr "$cluster" -r '.Engine');              [[ "$engine" != aurora* ]] && continue

    members_len=$(echo "$cluster" | jq '(.DBClusterMembers // []) | length' 2>/dev/null || echo 0)

    if [[ "$members_len" -gt 0 ]]; then
      readers=$(echo "$cluster" | jq '[(.DBClusterMembers // [])[] | select(.IsClusterWriter == false)] | length' 2>/dev/null || echo 0)
      total=$members_len
    else
      total=$(echo "$RDS_INSTANCES" | jq --arg c "$cid" '[.[] | select(.DBClusterIdentifier == $c)] | length' 2>/dev/null || echo 0)
      writers=$(echo "$RDS_INSTANCES" | jq --arg c "$cid" \
        '[.[] | select(.DBClusterIdentifier == $c) | select((.ReadReplicaSourceDBInstanceIdentifier // "") == "")] | length' \
        2>/dev/null || echo 0)
      readers=$((total - writers))
      [[ $readers -lt 0 ]] && readers=0
    fi

    if [[ "$total" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine): NO instances found -- cluster is empty, RTO: undefined"
    elif [[ "$readers" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine): $total instance(s) present, all writers, NO readers -- no failover target, RTO: 10-15 minutes"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r gc; do
    local gcid gc_members
    gcid=$(jqr "$gc" -r '.GlobalClusterIdentifier');    [[ -z "$gcid" ]] && continue
    gc_members=$(echo "$gc" | jq '(.GlobalClusterMembers // []) | length' 2>/dev/null || echo 0)
    [[ "$gc_members" -gt 1 ]] && blocker "FT-08" HIGH "Global cluster '$gcid': secondary cluster readers restart during primary failover -- secondary unavailable during the event"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]' 2>/dev/null)
}

# =============================================================================
# CATEGORY 2: SNAPSHOT RESTORE (SR)
# =============================================================================
check_snapshot_restore() {
  html_section_open "sr" "Category 2: Snapshot Restore Constraints (SR)"
  header "Category 2: Snapshot Restore Constraints (SR)"

  blocker "SR-01" MEDIUM "Snapshot restore uses lazy loading from S3 -- 'available' does NOT mean performant. Pre-warm with pg_prewarm after restore."
  blocker "SR-03" HIGH   "Snapshot restore ALWAYS creates a NEW instance -- existing endpoints will NOT point to it. Update connection strings post-restore."

  while IFS= read -r snap; do
    local snapid
    snapid=$(jqr "$snap" -r '.DBClusterSnapshotIdentifier'); [[ -z "$snapid" || "$snapid" == "null" ]] && continue
    blocker "SR-05" MEDIUM "Cluster snapshot '$snapid': restore assigns DEFAULT parameter group -- custom tuning is lost"
  done < <(echo "$CLUSTER_SNAPSHOTS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r snap; do
    local snapid
    snapid=$(jqr "$snap" -r '.DBSnapshotIdentifier'); [[ -z "$snapid" || "$snapid" == "null" ]] && continue
    blocker "SR-05" MEDIUM "Instance snapshot '$snapid': restore assigns DEFAULT parameter group -- custom tuning is lost"
  done < <(echo "$INSTANCE_SNAPSHOTS" | jq -c '.[]' 2>/dev/null)

  blocker "SR-06" HIGH "Restored instances get DEFAULT security group -- DB may be unreachable. Apply correct SG immediately after restore."

  while IFS= read -r cluster; do
    local cid engine pitr
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');    [[ -z "$cid" ]] && continue
    engine=$(jqr "$cluster" -r '.Engine')
    pitr=$(jqr "$cluster" -r '.BackupRetentionPeriod')
    [[ "$engine" == aurora* ]] && blocker "SR-07" MEDIUM "Aurora cluster '$cid': PITR restores cluster only -- reader instances must be re-added separately (+5-10 min each)"
    [[ "$pitr" -gt 0 ]] 2>/dev/null && blocker "SR-08" MEDIUM "Cluster '$cid': PITR transaction logs flushed every 5 min -- minimum achievable RPO is 5 minutes"
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r inst; do
    local id storage
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    storage=$(jqr "$inst" -r '.AllocatedStorage'); storage=${storage:-0}
    if   [[ "$storage" -gt 500 ]]; then blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO ~60-180 min"
    elif [[ "$storage" -gt 100 ]]; then blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO ~30-60 min"
    else                                blocker "SR-10" INFO "Instance '$id' (${storage}GB): snapshot restore RTO ~15-30 min"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)
}

# =============================================================================
# CATEGORY 3: ENCRYPTION (EN)
# =============================================================================
check_encryption() {
  html_section_open "en" "Category 3: Encryption Constraints (EN)"
  header "Category 3: Encryption Constraints (EN)"

  while IFS= read -r inst; do
    local id enc engine kms
    id=$(jqr "$inst" -r '.DBInstanceIdentifier');   [[ -z "$id" ]] && continue
    enc=$(jqr "$inst" -r '.StorageEncrypted')
    engine=$(jqr "$inst" -r '.Engine')
    kms=$(jqr "$inst" -r '.KmsKeyId // ""')
    [[ "$engine" == aurora* ]] && continue
    if [[ "$enc" == "false" ]]; then
      blocker "EN-01" HIGH "RDS instance '$id' is UNENCRYPTED -- encryption requires snapshot-encrypt-restore migration"
      blocker "EN-04" HIGH "RDS instance '$id' is UNENCRYPTED -- cross-region replicas are BLOCKED until encrypted"
    elif echo "$kms" | grep -q "aws/rds"; then
      blocker "EN-05" MEDIUM "RDS instance '$id' uses AWS-managed key (aws/rds) -- cross-account snapshot copy BLOCKED. Migrate to CMK."
      blocker "EN-03" MEDIUM "RDS instance '$id': cross-region copies require pre-provisioned CMK in destination region"
    else
      blocker "EN-03" MEDIUM "RDS instance '$id': cross-region snapshot copies require re-encryption with destination CMK"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r cluster; do
    local cid enc kms
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier'); [[ -z "$cid" ]] && continue
    enc=$(jqr "$cluster" -r '.StorageEncrypted')
    kms=$(jqr "$cluster" -r '.KmsKeyId // ""')
    if [[ "$enc" == "false" ]]; then
      blocker "EN-01" HIGH "Aurora cluster '$cid' is UNENCRYPTED -- Global DB and cross-region replicas are BLOCKED"
      blocker "EN-04" HIGH "Aurora cluster '$cid' is UNENCRYPTED -- ALL cross-region DR paths are BLOCKED"
    elif echo "$kms" | grep -q "aws/rds"; then
      blocker "EN-05" MEDIUM "Aurora cluster '$cid' uses AWS-managed key -- cross-account snapshot copy BLOCKED. Migrate to CMK."
      blocker "EN-03" MEDIUM "Aurora cluster '$cid': cross-region snapshot copies require pre-provisioned CMK in destination region"
    else
      blocker "EN-03" MEDIUM "Aurora cluster '$cid': cross-region snapshot copies require re-encryption with destination CMK"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r gc; do
    local gcid
    gcid=$(jqr "$gc" -r '.GlobalClusterIdentifier'); [[ -z "$gcid" ]] && continue
    blocker "EN-06" CRITICAL "Global cluster '$gcid': KMS key inaccessible 7+ days = TERMINAL -- no recovery possible. Enable KMS key deletion alarms now."
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]' 2>/dev/null)
}

# =============================================================================
# CATEGORY 4: KMS THROTTLING (KT)
# =============================================================================
check_kms_throttling() {
  html_section_open "kt" "Category 4: KMS API Throttling (KT)"
  header "Category 4: KMS API Throttling (KT)"

  local enc_count
  enc_count=$(echo "$RDS_INSTANCES" | jq '[.[] | select(.StorageEncrypted==true)] | length' 2>/dev/null || echo 0)
  blocker "KT-01" MEDIUM "KMS symmetric ops quota: ${KMS_QUOTA} req/s shared across $enc_count encrypted instances -- parallel restores compete for this quota"
  blocker "KT-02" HIGH   "KMS quota is SHARED across ALL services (RDS, S3, EBS, Lambda) on the same key -- DR-time contention is likely"
  blocker "KT-03" HIGH   "Exceeding KMS quota returns ThrottlingException -- parallel encrypted restores may stall silently during DR"
  blocker "KT-04" HIGH   "KMS CreateGrant quota: 50 req/s -- each RDS encrypted operation consumes one grant. Fleet restores will bottleneck here."
}

# =============================================================================
# CATEGORY 5: CROSS-REGION DR (CR)
# =============================================================================
check_cross_region_dr() {
  html_section_open "cr" "Category 5: Cross-Region DR Constraints (CR)"
  header "Category 5: Cross-Region DR Constraints (CR)"

  local GLOBAL_ARNS
  GLOBAL_ARNS=$(echo "$GLOBAL_CLUSTERS" | jq -r '[.[].GlobalClusterMembers[].DBClusterArn] | @json' 2>/dev/null || echo "[]")

  while IFS= read -r cluster; do
    local cid engine arn in_global
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');  [[ -z "$cid" ]] && continue
    engine=$(jqr "$cluster" -r '.Engine');             [[ "$engine" != aurora* ]] && continue
    arn=$(jqr "$cluster" -r '.DBClusterArn')
    in_global=$(echo "$GLOBAL_ARNS" | jq --arg a "$arn" 'map(select(. == $a)) | length > 0' 2>/dev/null || echo "false")
    [[ "$in_global" == "false" ]] && blocker "CR-01" HIGH "Aurora cluster '$cid' is NOT in a Global DB -- no automated cross-region backup replication. Manual snapshot copies required."
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r gc; do
    local gcid ver status
    gcid=$(jqr "$gc" -r '.GlobalClusterIdentifier'); [[ -z "$gcid" ]] && continue
    ver=$(jqr "$gc" -r '.EngineVersion')
    status=$(jqr "$gc" -r '.Status')
    blocker "CR-05" CRITICAL "Global cluster '$gcid' (v$ver, $status): switchover requires identical major+minor version -- version drift silently blocks DR"
    blocker "CR-06" HIGH     "Global cluster '$gcid': patch level drift between members can break DR without warning"
    blocker "CR-08" MEDIUM   "Global cluster '$gcid': secondary clusters do NOT support Auto Scaling -- may be under-provisioned after failover"
    blocker "CR-10" MEDIUM   "Global cluster '$gcid': Secrets Manager rotation NOT supported -- manual credential coordination required across regions"
    blocker "CR-14" MEDIUM   "Global cluster '$gcid': replication is ASYNC -- sub-second typical but NOT guaranteed under load. RPO > 0 must be accepted."
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  while IFS= read -r cluster; do
    local cid amvu arn in_global
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');      [[ -z "$cid" ]] && continue
    amvu=$(jqr "$cluster" -r '.AutoMinorVersionUpgrade // "false"')
    arn=$(jqr "$cluster" -r '.DBClusterArn')
    in_global=$(echo "$GLOBAL_ARNS" | jq --arg a "$arn" 'map(select(. == $a)) | length > 0' 2>/dev/null || echo "false")
    [[ "$in_global" == "true" && "$amvu" == "true" ]] && \
      blocker "CR-11" MEDIUM "Cluster '$cid' in Global DB with AutoMinorVersionUpgrade=true -- auto minor upgrades have NO EFFECT; coordinate manually"
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)
}

# =============================================================================
# CATEGORY 6: APPLICATION LAYER (AL)
# =============================================================================
check_application_layer() {
  html_section_open "al" "Category 6: Application-Layer Resilience (AL)"
  header "Category 6: Application-Layer Resilience (AL)"

  local proxy_count
  proxy_count=$(echo "$PROXIES" | jq 'length' 2>/dev/null || echo 0)

  while IFS= read -r cluster; do
    local cid has_proxy
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier'); [[ -z "$cid" ]] && continue
    has_proxy=$(echo "$PROXIES" | jq --arg c "$cid" \
      '[.[] | select((.DBProxyName | ascii_downcase | contains($c | ascii_downcase)) or (.Endpoint | ascii_downcase | contains($c | ascii_downcase)))] | length > 0' \
      2>/dev/null || echo "false")
    [[ "$has_proxy" == "false" ]] && \
      blocker "AL-01" HIGH "Cluster '$cid' has NO RDS Proxy -- failover relies on DNS (5-60s stale routing). Deploy RDS Proxy or AWS JDBC Wrapper."
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  blocker "AL-02" HIGH   "Connection pools hold stale connections after failover -- errors until pool cycles. Configure connection validation and short pool TTL."
  blocker "AL-03" MEDIUM "TCP keepalive defaults are 2+ hours -- dead connections take minutes to detect. Set tcp_keepalive_time=60 on DB clients."

  [[ "$proxy_count" -gt 0 ]] && \
    blocker "AL-04" MEDIUM "RDS Proxy detected ($proxy_count): after Global DB failover, Proxy in old primary region still points to demoted instance -- update targets."

  while IFS= read -r gc; do
    local gcid engine
    gcid=$(jqr "$gc" -r '.GlobalClusterIdentifier');  [[ -z "$gcid" ]] && continue
    engine=$(jqr "$gc" -r '.Engine')
    [[ "$engine" == aurora-postgresql* ]] && \
      blocker "AL-06" MEDIUM "Global cluster '$gcid' (PostgreSQL): Cluster Cache Management NOT supported on secondary -- cold buffer pool after failover"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  blocker "FT-06" MEDIUM "Verify all Java clients: networkaddress.cache.ttl=60 -- default JVM DNS TTL is INFINITE, preventing reconnection after failover."
}

# =============================================================================
# CATEGORY 7: ACCOUNT QUOTAS (QT)
# =============================================================================
check_account_quotas() {
  html_section_open "qt" "Category 7: Account-Level Service Quotas (QT)"
  header "Category 7: Account-Level Service Quotas (QT)"

  local snap_count isnap_count gc_count proxy_count

  snap_count=$(echo "$CLUSTER_SNAPSHOTS"  | jq 'length' 2>/dev/null || echo 0)
  isnap_count=$(echo "$INSTANCE_SNAPSHOTS" | jq 'length' 2>/dev/null || echo 0)
  gc_count=$(echo "$GLOBAL_CLUSTERS"      | jq 'length' 2>/dev/null || echo 0)
  proxy_count=$(echo "$PROXIES"           | jq 'length' 2>/dev/null || echo 0)

  if [[ "$snap_count"   -ge 90 ]]; then blocker "QT-01" HIGH "Manual cluster snapshots: $snap_count/100 -- approaching limit. DR copies will fail when limit is hit."
  else ok "Manual cluster snapshots: $snap_count/100"; fi

  if [[ "$isnap_count"  -ge 90 ]]; then blocker "QT-02" HIGH "Manual instance snapshots: $isnap_count/100 -- approaching limit."
  else ok "Manual instance snapshots: $isnap_count/100"; fi

  if [[ "$INSTANCE_COUNT" -ge 36 ]]; then blocker "QT-03" CRITICAL "DB instances: $INSTANCE_COUNT/40 -- approaching regional limit. DR restore WILL FAIL when limit is reached."
  else ok "DB instances: $INSTANCE_COUNT/40"; fi

  if [[ "$CLUSTER_COUNT"  -ge 36 ]]; then blocker "QT-04" CRITICAL "DB clusters: $CLUSTER_COUNT/40 -- approaching regional limit."
  else ok "DB clusters: $CLUSTER_COUNT/40"; fi

  blocker "QT-07" HIGH "Concurrent cross-region snapshot copies: hard limit is 5. Multiple simultaneous DR copies will queue and delay recovery."

  if [[ "$gc_count"     -ge 5  ]]; then blocker "QT-10" MEDIUM "Aurora Global Databases: $gc_count/5 -- at regional limit."
  else ok "Aurora Global Databases: $gc_count/5"; fi

  blocker "QT-15" HIGH "KMS CreateGrant quota: 50 req/s -- fleet-wide encrypted restores will bottleneck here."

  if [[ "$proxy_count"  -ge 18 ]]; then blocker "QT-19" MEDIUM "RDS Proxies: $proxy_count/20 -- approaching limit."
  else ok "RDS Proxies: $proxy_count/20"; fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
  header "ASSESSMENT SUMMARY"
  log ""
  log "  Region    : $AWS_REGION"
  log "  Instances : $INSTANCE_COUNT"
  log "  Clusters  : $CLUSTER_COUNT"
  log ""
  log "  ${RED}${BOLD}CRITICAL : $CRITICAL${RESET}"
  log "  ${YELLOW}${BOLD}HIGH     : $HIGH${RESET}"
  log "  ${CYAN}MEDIUM   : $MEDIUM${RESET}"
  log "  ${GREEN}LOW      : $LOW${RESET}"
  log "  INFO     : $INFO_COUNT"
  log ""
  if   [[ "$CRITICAL" -gt 0 ]]; then log "  ${RED}${BOLD}VERDICT: CRITICAL BLOCKERS FOUND -- DR is broken or severely limited${RESET}"
  elif [[ "$HIGH"     -gt 0 ]]; then log "  ${YELLOW}${BOLD}VERDICT: HIGH-SEVERITY BLOCKERS -- DR paths exist but are unreliable${RESET}"
  elif [[ "$MEDIUM"   -gt 0 ]]; then log "  ${CYAN}VERDICT: MEDIUM ISSUES -- DR possible but recovery times degraded${RESET}"
  else                               log "  ${GREEN}${BOLD}VERDICT: No blockers found${RESET}"; fi
  log ""
  log "  HTML report: $OUTPUT_HTML"

  html_summary "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW" "$INFO_COUNT"
  html_close
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  html_init
  log "================================================================"
  log "  RBUI -- RDS/Aurora Resilience Blocker Assessment v1.1.0"
  log "  $(date)"
  log "================================================================"

  local acct
  acct=$(check_prereqs)
  html_meta "$acct"
  html_toc

  collect_data
  check_failover_timing
  check_snapshot_restore
  check_encryption
  check_kms_throttling
  check_cross_region_dr
  check_application_layer
  check_account_quotas
  print_summary

  log ""
  log "  ${GREEN}${BOLD}Report saved: $OUTPUT_HTML${RESET}"
  log "  Open in any browser: open $OUTPUT_HTML"
}

main "$@"
