#!/usr/bin/env bash
# =============================================================================
# rbui-check.sh — RDS/Aurora Resilience Blocker Assessment
# Converted from: https://github.com/aws-samples/sample-kiro-rbui-agent
# Output: HTML report (rbui-report-YYYYMMDD-HHMMSS.html)
# Read-only: uses only describe/list/get AWS API calls (+ optional DNS lookups)
#
# Usage: rbui-check [REGION] [DR_REGION]
#   REGION     region to assess (default: us-east-1)
#   DR_REGION  optional target DR region; enables KMS readiness checks (EN-03)
#
# Severity model:
#   CRITICAL/HIGH/MEDIUM/LOW  findings derived from your account data (counted)
#   INFO                      data-derived informational items
#   ADVISORY                  generic best-practice reminders that the script
#                             CANNOT verify from AWS APIs -- not counted in the
#                             verdict; verify manually
# Compatible with bash 3.2+ (macOS default) -- no associative arrays.
# =============================================================================

# NOTE: Do NOT use set -e — arithmetic like VAR=$((VAR+1)) is safe but
# the older ((VAR++)) form returns exit 1 when VAR=0 under set -e.
set -uo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
RBUI_VERSION="1.3.0"
AWS_REGION="${1:-us-east-1}"
DR_REGION="${2:-${RBUI_DR_REGION:-}}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_HTML="rbui-report-${TIMESTAMP}.html"
ACCOUNT_ID="UNKNOWN"

# Severity counters
CRITICAL=0; HIGH=0; MEDIUM=0; LOW=0; INFO_COUNT=0; ADVISORY_COUNT=0

# KMS key cache: newline-separated "arn|KeyManager|MultiRegion" (bash 3.2 safe)
KMS_CACHE=""
KMS_MANAGER=""; KMS_MULTI=""; DRK_STATUS=""; DRK_DETAIL=""

# Temp files: API stderr capture + list of failed API calls
RBUI_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/rbui_err.XXXXXX")
RBUI_FAILED_FILE=$(mktemp "${TMPDIR:-/tmp}/rbui_failed.XXXXXX")
trap 'rm -f "$RBUI_ERR_FILE" "$RBUI_FAILED_FILE"' EXIT

# api_failed LABEL -> true if that collection call failed
api_failed() { grep -qxF "$1" "$RBUI_FAILED_FILE" 2>/dev/null; }

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
.ADVISORY{color:#6c5b7b;background:#f5f0fa;}
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
.sa{color:#6c5b7b;background:#f5f0fa;}
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
  printf '<div class="meta">Account: <strong>%s</strong> &nbsp;|&nbsp; Region: <strong>%s</strong> &nbsp;|&nbsp; DR region: <strong>%s</strong> &nbsp;|&nbsp; Generated: <strong>%s</strong></div>\n' \
    "$1" "$AWS_REGION" "${DR_REGION:-not specified}" "$(date)" >> "$OUTPUT_HTML"
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
  local c="$1" h="$2" m="$3" l="$4" i="$5" a="$6"
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
  <div class="sb sa">$a<span>Advisory</span></div>
</div>
<div class="verdict $vcls">$vtxt</div>
<p style="margin:0 16px 16px;color:#6c5b7b;font-size:.85em">ADVISORY items are generic best-practice reminders that cannot be verified from AWS APIs. They are not counted in the verdict &mdash; verify them manually.</p>
<table>
<tr><th>Priority</th><th>When</th><th>Focus</th></tr>
<tr><td><strong>P1 &mdash; Immediate</strong></td><td>Today</td><td>All CRITICAL items</td></tr>
<tr><td><strong>P2 &mdash; This week</strong></td><td>1&ndash;7 days</td><td>All HIGH items</td></tr>
<tr><td><strong>P3 &mdash; 30 days</strong></td><td>This month</td><td>All MEDIUM items</td></tr>
</table></div>
SUMHTML
}

html_close() {
  printf '<footer>RBUI v%s &nbsp;|&nbsp; Read-only assessment &nbsp;|&nbsp; Based on <a href="https://github.com/aws-samples/sample-kiro-rbui-agent">aws-samples/sample-kiro-rbui-agent</a></footer>\n</body></html>\n' "$RBUI_VERSION" >> "$OUTPUT_HTML"
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
    ADVISORY) ADVISORY_COUNT=$((ADVISORY_COUNT+1)); colour="${RESET}"; label="[ADVISORY]" ;;
  esac
  log "  ${colour}${label} ${BOLD}${id}${RESET} -- ${msg}"
  html_row "$sev" "$id" "$msg"
}

# Generic, unverifiable reminder -- not counted in the verdict
advisory() { blocker "$1" ADVISORY "$2"; }

# dns_ttl HOST -> prints the TTL (seconds) of the first answer record, or "" if
# dig is unavailable / lookup fails. Note: a caching resolver returns the
# REMAINING TTL, so the value can be lower than the authoritative TTL.
dns_ttl() {
  local host="$1" ttl=""
  [[ -z "$host" || "$host" == "null" ]] && { echo ""; return; }
  command -v dig &>/dev/null || { echo ""; return; }
  ttl=$(dig +noall +answer +time=2 +tries=1 "$host" 2>/dev/null | awk 'NR==1{print $2}')
  [[ "$ttl" =~ ^[0-9]+$ ]] && echo "$ttl" || echo ""
}

# kms_key_info KEY_ARN -> sets KMS_MANAGER (AWS/CUSTOMER/UNKNOWN) and
# KMS_MULTI (true/false/UNKNOWN). Must be called directly (not via $(...))
# so the cache in KMS_CACHE persists between calls.
kms_key_info() {
  local key="$1" hit out region
  hit=$(printf '%s\n' "$KMS_CACHE" | grep -F "${key}|" | head -1)
  if [[ -n "$hit" ]]; then
    out="${hit#"${key}|"}"
    KMS_MANAGER="${out%%|*}"; KMS_MULTI="${out#*|}"
    return
  fi
  # Key ARNs are arn:aws:kms:<region>:<acct>:key/<id>; query the key's own region
  region=$(echo "$key" | awk -F: '{print $4}'); region=${region:-$AWS_REGION}
  out=$(aws kms describe-key --key-id "$key" --region "$region" \
          --query 'KeyMetadata.[KeyManager,MultiRegion]' --output text 2>/dev/null \
        | awk '{print $1"|"tolower($2)}')
  [[ -z "$out" || "$out" == "|" ]] && out="UNKNOWN|UNKNOWN"
  KMS_CACHE="${KMS_CACHE}${key}|${out}"$'\n'
  KMS_MANAGER="${out%%|*}"; KMS_MULTI="${out#*|}"
}

# kms_dr_key_check KEY_ARN MULTIREGION -> sets DRK_STATUS (OK/MISSING/UNKNOWN)
# and DRK_DETAIL describing key readiness in $DR_REGION.
kms_dr_key_check() {
  local key="$1" multi="$2" replica cmk_count
  DRK_STATUS="UNKNOWN"; DRK_DETAIL=""
  if [[ "$multi" == "true" ]]; then
    # Multi-Region key: replica in DR region shares the same key id
    replica=$(echo "$key" | awk -F: -v r="$DR_REGION" 'BEGIN{OFS=":"}{$4=r; print}')
    if aws kms describe-key --key-id "$replica" --region "$DR_REGION" &>/dev/null; then
      DRK_STATUS="OK";      DRK_DETAIL="multi-Region key replica exists in $DR_REGION"
    else
      DRK_STATUS="MISSING"; DRK_DETAIL="multi-Region key is NOT replicated to $DR_REGION (or DescribeKey denied)"
    fi
    return
  fi
  # Single-Region CMK: need any customer-managed key aliased in the DR region
  cmk_count=$(aws kms list-aliases --region "$DR_REGION" --output json 2>/dev/null \
    | jq '[.Aliases[] | select(.TargetKeyId != null) | select(.AliasName | startswith("alias/aws/") | not)] | length' 2>/dev/null)
  if [[ -z "$cmk_count" ]]; then
    DRK_STATUS="UNKNOWN"; DRK_DETAIL="could not list KMS aliases in $DR_REGION (permission?)"
  elif [[ "$cmk_count" -gt 0 ]]; then
    DRK_STATUS="OK";      DRK_DETAIL="$cmk_count customer-managed key alias(es) found in $DR_REGION -- confirm one is designated for RDS DR copies"
  else
    DRK_STATUS="MISSING"; DRK_DETAIL="NO customer-managed key alias found in $DR_REGION"
  fi
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
  # Called directly (not in a subshell) so 'exit 1' really stops the script
  # and the log lines below reach the terminal instead of a variable.
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
  [[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="UNKNOWN"
  if [[ "$ACCOUNT_ID" == "UNKNOWN" ]]; then
    echo "ERROR: AWS credentials invalid. Run 'aws sts get-caller-identity'." >&2
    rm -f "$OUTPUT_HTML"; exit 1
  fi
  log "  Account   : $ACCOUNT_ID"
  log "  Region    : $AWS_REGION"
  log "  DR region : ${DR_REGION:-not specified (pass as 2nd arg to enable KMS DR checks)}"
  log "  Report    : $OUTPUT_HTML"
  if ! command -v dig &>/dev/null; then
    log "  ${YELLOW}[WARN]${RESET} 'dig' not found -- DNS TTLs will not be measured (FT-04/FT-05 become ADVISORY)"
  fi
}

# =============================================================================
# DATA COLLECTION
# =============================================================================
collect_data() {
  html_section_open "collect" "Data Collection"
  header "Collecting RDS/Aurora topology..."

  # _aws runs inside $(...), so failures are recorded in a file (a variable
  # set in the subshell would be lost); checks consult it via api_failed.
  _aws() {
    local label="$1"; shift
    local out
    out=$(aws "$@" --output json 2>"$RBUI_ERR_FILE") || {
      echo "$label" >> "$RBUI_FAILED_FILE"
      local err; err=$(head -1 "$RBUI_ERR_FILE")
      # Warning goes to stderr: stdout is captured as JSON by the caller
      log "  ${YELLOW}[WARN]${RESET} $label failed: $err" >&2
      html_row "HIGH" "API" "$label failed: $err -- related checks are INCOMPLETE"
      echo "[]"; return
    }
    echo "$out"
  }

  RDS_INSTANCES=$(_aws "describe-db-instances"     rds describe-db-instances     --region "$AWS_REGION" --query 'DBInstances[*]')
  RDS_CLUSTERS=$(_aws  "describe-db-clusters"      rds describe-db-clusters      --region "$AWS_REGION" --query 'DBClusters[*]')
  GLOBAL_CLUSTERS=$(_aws "describe-global-clusters" rds describe-global-clusters --region "$AWS_REGION" --query 'GlobalClusters[*]')
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

  # FT-03 / FT-05: only meaningful for non-Aurora RDS instances that CAN fail
  # over (Multi-AZ). Single-AZ instances are already covered by FT-09.
  local ft03_ids=""
  while IFS= read -r inst; do
    local id engine maz addr ttl
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    engine=$(jqr "$inst" -r '.Engine')
    maz=$(jqr "$inst" -r '.MultiAZ')
    [[ "$engine" == aurora* || "$maz" != "true" ]] && continue
    ft03_ids="${ft03_ids:+$ft03_ids, }$id"

    addr=$(jqr "$inst" -r '.Endpoint.Address // ""')
    ttl=$(dns_ttl "$addr")
    if [[ -n "$ttl" ]]; then
      blocker "FT-05" MEDIUM "RDS instance '$id': endpoint DNS TTL measured at ${ttl}s ($addr) -- clients may route to the old primary for up to ${ttl}s after failover (resolver-cached values can read lower than the authoritative TTL)"
    else
      advisory "FT-05" "RDS instance '$id': endpoint DNS TTL NOT measured (dig unavailable or lookup failed) -- run 'dig +noall +answer $addr' to verify the stale-routing window"
    fi
  done < <(echo "$RDS_INSTANCES" | jq -c '.[]' 2>/dev/null)

  [[ -n "$ft03_ids" ]] && advisory "FT-03" "Multi-AZ RDS instance(s) [$ft03_ids]: long-running/large open transactions extend crash recovery and failover beyond the typical 60-120s -- NOT measured; check pg_stat_activity (xact_start) at peak load"

  # FT-04: Aurora cluster (writer) endpoint TTL, measured per cluster with instances
  while IFS= read -r cluster; do
    local cid engine ep ttl n
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier'); [[ -z "$cid" ]] && continue
    engine=$(jqr "$cluster" -r '.Engine');           [[ "$engine" != aurora* ]] && continue
    n=$(echo "$cluster" | jq '(.DBClusterMembers // []) | length' 2>/dev/null || echo 0)
    [[ "$n" -eq 0 ]] && continue
    ep=$(jqr "$cluster" -r '.Endpoint // ""')
    ttl=$(dns_ttl "$ep")
    if [[ -n "$ttl" ]]; then
      if [[ "$ttl" -gt 5 ]]; then
        blocker "FT-04" MEDIUM "Aurora cluster '$cid': writer endpoint DNS TTL measured at ${ttl}s ($ep) -- higher than the expected 5s; stale routing window after failover is at least ${ttl}s"
      else
        advisory "FT-04" "Aurora cluster '$cid': writer endpoint DNS TTL measured at ${ttl}s -- OK at DNS level, but client/OS/driver DNS caching can still extend the stale routing window"
      fi
    else
      advisory "FT-04" "Aurora cluster '$cid': writer endpoint DNS TTL NOT measured -- run 'dig +noall +answer $ep' (expected 5s)"
    fi
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)

  # FT-06: cannot be checked from AWS APIs -- application host setting
  advisory "FT-06" "Java clients: JVM DNS caching is INFINITE only when a SecurityManager is installed; otherwise the OpenJDK default is ~30s. NOT verifiable from AWS APIs -- check networkaddress.cache.ttl in java.security and -Dsun.net.inetaddr.ttl / -Djava.security.manager on app hosts; set an explicit TTL <=60s"

  # FT-07 / FT-10: reader presence and AZ placement.
  # DBClusterMembers[].IsClusterWriter is authoritative. If DBClusterMembers is
  # empty but describe-db-instances lists instances for the cluster, roles can't
  # be determined reliably (ReadReplicaSourceDBInstanceIdentifier is NOT set on
  # Aurora readers), so report UNVERIFIED instead of a false CRITICAL.
  while IFS= read -r cluster; do
    local cid engine members_len readers total inst_total evidence writer_az other_az_readers
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');    [[ -z "$cid" ]]  && continue
    engine=$(jqr "$cluster" -r '.Engine');              [[ "$engine" != aurora* ]] && continue

    members_len=$(echo "$cluster" | jq '(.DBClusterMembers // []) | length' 2>/dev/null || echo 0)
    inst_total=$(echo "$RDS_INSTANCES" | jq --arg c "$cid" '[.[] | select(.DBClusterIdentifier == $c)] | length' 2>/dev/null || echo 0)

    if [[ "$members_len" -eq 0 && "$inst_total" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine): NO instances (DBClusterMembers empty, no instances in describe-db-instances) -- cluster has no compute, RTO undefined until an instance is added"
      continue
    fi
    if [[ "$members_len" -eq 0 ]]; then
      blocker "FT-07" MEDIUM "Aurora cluster '$cid' ($engine): $inst_total instance(s) found but DBClusterMembers is empty -- reader/writer roles UNVERIFIED; check with 'aws rds describe-db-clusters --db-cluster-identifier $cid'"
      continue
    fi

    total=$members_len
    readers=$(echo "$cluster" | jq '[.DBClusterMembers[] | select(.IsClusterWriter == false)] | length' 2>/dev/null || echo 0)

    # Evidence: "id (writer|reader, az)" for each member, AZ from describe-db-instances
    evidence=$(jq -rn --argjson c "$cluster" --argjson i "$RDS_INSTANCES" '
      ($i | map({key: .DBInstanceIdentifier, value: (.AvailabilityZone // "?")}) | from_entries) as $az
      | [$c.DBClusterMembers[] | "\(.DBInstanceIdentifier) (\(if .IsClusterWriter then "writer" else "reader" end), \($az[.DBInstanceIdentifier] // "?"))"]
      | join(", ")' 2>/dev/null || echo "?")

    if [[ "$readers" -eq 0 ]]; then
      blocker "FT-07" CRITICAL "Aurora cluster '$cid' ($engine): NO readers -- members: $evidence. No failover target: on writer failure Aurora recreates the instance best-effort (typically ~10 min, not guaranteed during an AZ outage). Add a reader in a different AZ."
      continue
    fi

    # FT-10: at least one reader must be outside the writer's AZ
    writer_az=$(jq -rn --argjson c "$cluster" --argjson i "$RDS_INSTANCES" '
      ([$c.DBClusterMembers[] | select(.IsClusterWriter) | .DBInstanceIdentifier][0]) as $w
      | ([$i[] | select(.DBInstanceIdentifier == $w) | .AvailabilityZone][0] // "")' 2>/dev/null || echo "")
    other_az_readers=$(jq -rn --argjson c "$cluster" --argjson i "$RDS_INSTANCES" --arg waz "$writer_az" '
      [$c.DBClusterMembers[] | select(.IsClusterWriter == false) | .DBInstanceIdentifier] as $r
      | [$i[] | select(.DBInstanceIdentifier as $x | $r | index($x)) | select(.AvailabilityZone != $waz)] | length' 2>/dev/null || echo 0)
    if [[ -n "$writer_az" && "$other_az_readers" -eq 0 ]]; then
      blocker "FT-10" HIGH "Aurora cluster '$cid': all $readers reader(s) are in the writer's AZ ($writer_az) -- members: $evidence. Instance failure is covered, AZ failure is NOT."
    else
      ok "Aurora cluster '$cid': $readers reader(s), at least one outside the writer AZ -- members: $evidence"
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

  advisory "SR-01" "Snapshot restore uses lazy loading from S3 -- 'available' does NOT mean performant. Pre-warm (e.g. pg_prewarm) after restore."
  advisory "SR-03" "Snapshot restore ALWAYS creates a NEW instance/cluster -- existing endpoints will NOT point to it. Plan DNS/connection-string cutover in the runbook."

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

  advisory "SR-06" "Restores without explicit --vpc-security-group-ids get the DEFAULT security group -- DB may be unreachable. Specify SGs in the restore command."

  local sr07_ids="" sr08_ids=""
  while IFS= read -r cluster; do
    local cid engine pitr members_len
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier');    [[ -z "$cid" ]] && continue
    engine=$(jqr "$cluster" -r '.Engine')
    pitr=$(jqr "$cluster" -r '.BackupRetentionPeriod')
    # Empty clusters are already CRITICAL under FT-07; PITR notes aren't actionable
    members_len=$(echo "$cluster" | jq '(.DBClusterMembers // []) | length' 2>/dev/null || echo 0)
    [[ "$members_len" -eq 0 ]] && continue
    [[ "$engine" == aurora* ]] && sr07_ids="${sr07_ids:+$sr07_ids, }$cid"
    [[ "$pitr" -gt 0 ]] 2>/dev/null && sr08_ids="${sr08_ids:+$sr08_ids, }$cid"
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)
  [[ -n "$sr07_ids" ]] && advisory "SR-07" "Aurora cluster(s) [$sr07_ids]: PITR/snapshot restore creates the cluster only -- writer and reader instances must be added separately (+5-10 min each)"
  [[ -n "$sr08_ids" ]] && advisory "SR-08" "Cluster(s) [$sr08_ids]: PITR latest restorable time typically lags ~5 min -- plan for RPO of minutes when restoring from backups"

  while IFS= read -r inst; do
    local id storage engine
    id=$(jqr "$inst" -r '.DBInstanceIdentifier'); [[ -z "$id" ]] && continue
    engine=$(jqr "$inst" -r '.Engine')
    # Aurora AllocatedStorage is a placeholder (1) -- cluster volume size isn't
    # exposed here, so a storage-based RTO estimate would be misleading
    [[ "$engine" == aurora* ]] && continue
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

  # Non-Aurora instances that are not members of a cluster, then all clusters.
  # Aurora instances inherit encryption from their cluster, so they're skipped.
  local resources
  resources=$( {
    echo "$RDS_INSTANCES" | jq -r '.[] | select((.Engine | startswith("aurora")) | not) | select(.DBClusterIdentifier == null)
      | ["RDS instance", .DBInstanceIdentifier, (.StorageEncrypted|tostring), (.KmsKeyId // "")] | @tsv' 2>/dev/null
    echo "$RDS_CLUSTERS"  | jq -r '.[]
      | [(if (.Engine | startswith("aurora")) then "Aurora cluster" else "DB cluster" end), .DBClusterIdentifier, (.StorageEncrypted|tostring), (.KmsKeyId // "")] | @tsv' 2>/dev/null
  } )

  while IFS=$'\t' read -r kind rid enc kms; do
    [[ -z "${rid:-}" ]] && continue
    if [[ "$enc" != "true" ]]; then
      # One finding per resource (previously EN-01 + EN-04 double-counted).
      # Per AWS docs, unencrypted sources produce unencrypted snapshots/replicas
      # and encryption can't be enabled in place -- it does not by itself block
      # cross-region replication, but fixing it later forces a migration.
      blocker "EN-01" HIGH "$kind '$rid' is UNENCRYPTED -- encryption cannot be enabled in place; its snapshots and replicas (incl. DR copies) stay unencrypted. Fix requires restore with a KMS key or blue/green (new endpoint)."
      continue
    fi

    if [[ -z "$kms" || "$kms" == "null" ]]; then
      # Encrypted but no KmsKeyId exposed -> likely AWS-owned key (Aurora default since 2026-02-18)
      blocker "EN-05" MEDIUM "$kind '$rid' is encrypted but exposes no KmsKeyId (likely the AWS-owned default key) -- key policy cannot be managed; verify cross-account snapshot sharing and cross-region copy behavior before relying on it for DR"
      continue
    fi

    kms_key_info "$kms"
    case "$KMS_MANAGER" in
      AWS)
        blocker "EN-05" HIGH "$kind '$rid' uses the AWS-managed key aws/rds ($kms) -- snapshots CANNOT be shared cross-account (blocks cross-account DR/backup vault). Migrate: copy snapshot with a CMK and restore."
        ;;
      CUSTOMER)
        local ktype="single-Region CMK"; [[ "$KMS_MULTI" == "true" ]] && ktype="multi-Region CMK"
        if [[ -z "$DR_REGION" ]]; then
          advisory "EN-03" "$kind '$rid' uses a $ktype ($kms). Cross-region snapshot copy must name a key in the destination region -- pass a DR region as 2nd argument to verify readiness."
        else
          kms_dr_key_check "$kms" "$KMS_MULTI"
          case "$DRK_STATUS" in
            OK)      ok "$kind '$rid' ($ktype): $DRK_DETAIL" ;;
            MISSING) blocker "EN-03" HIGH   "$kind '$rid' ($ktype, $kms): $DRK_DETAIL -- cross-region snapshot copy/restore to $DR_REGION has no CMK to re-encrypt with" ;;
            *)       blocker "EN-03" MEDIUM "$kind '$rid' ($ktype): $DRK_DETAIL -- DR key readiness UNVERIFIED" ;;
          esac
        fi
        ;;
      *)
        blocker "EN-05" MEDIUM "$kind '$rid': could not describe KMS key ($kms) -- kms:DescribeKey denied or key in another account. Key type (AWS-managed vs CMK) UNVERIFIED."
        ;;
    esac
  done <<< "$resources"

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

  # Count encrypted resources the same way as Category 3: standalone non-Aurora
  # instances + all clusters (Aurora instances share their cluster's key)
  local enc_count
  enc_count=$(jq -n --argjson i "$RDS_INSTANCES" --argjson c "$RDS_CLUSTERS" '
    ([$i[] | select((.Engine | startswith("aurora")) | not) | select(.DBClusterIdentifier == null) | select(.StorageEncrypted == true)] | length)
    + ([$c[] | select(.StorageEncrypted == true)] | length)' 2>/dev/null || echo 0)
  advisory "KT-01" "KMS cryptographic ops quota in $AWS_REGION: ${KMS_QUOTA} req/s, shared by $enc_count encrypted RDS/Aurora resource(s) -- parallel restores compete for this quota"
  advisory "KT-02" "KMS request quotas are per account+region and SHARED across all services (RDS, S3, EBS, Lambda) -- DR-time contention possible; not measurable from config"
  advisory "KT-03" "Exceeding KMS quotas returns ThrottlingException -- test parallel encrypted restores in a DR drill to confirm they don't stall"
  advisory "KT-04" "KMS CreateGrant is rate-limited -- encrypted RDS creates/restores consume grants; stagger fleet-wide restores in the runbook"
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

  if api_failed "describe-db-proxies"; then
    blocker "AL-01" MEDIUM "RDS Proxy presence UNVERIFIED -- describe-db-proxies failed (see API row above). Grant rds:DescribeDBProxies and re-run."
  else
  while IFS= read -r cluster; do
    local cid has_proxy
    cid=$(jqr "$cluster" -r '.DBClusterIdentifier'); [[ -z "$cid" ]] && continue
    has_proxy=$(echo "$PROXIES" | jq --arg c "$cid" \
      '[.[] | select((.DBProxyName | ascii_downcase | contains($c | ascii_downcase)) or (.Endpoint | ascii_downcase | contains($c | ascii_downcase)))] | length > 0' \
      2>/dev/null || echo "false")
    [[ "$has_proxy" == "false" ]] && \
      blocker "AL-01" HIGH "Cluster '$cid' has NO RDS Proxy -- failover relies on DNS (5-60s stale routing). Deploy RDS Proxy or AWS JDBC Wrapper."
  done < <(echo "$RDS_CLUSTERS" | jq -c '.[]' 2>/dev/null)
  fi

  advisory "AL-02" "Connection pools can hold stale connections after failover -- NOT verifiable from AWS APIs; configure connection validation and a short max lifetime"
  advisory "AL-03" "OS TCP keepalive defaults are ~2 hours -- dead connections are detected slowly. NOT verifiable from AWS APIs; set client keepalive (e.g. 60s) on app hosts"

  [[ "$proxy_count" -gt 0 ]] && \
    blocker "AL-04" MEDIUM "RDS Proxy detected ($proxy_count): after Global DB failover, Proxy in old primary region still points to demoted instance -- update targets."

  while IFS= read -r gc; do
    local gcid engine
    gcid=$(jqr "$gc" -r '.GlobalClusterIdentifier');  [[ -z "$gcid" ]] && continue
    engine=$(jqr "$gc" -r '.Engine')
    [[ "$engine" == aurora-postgresql* ]] && \
      blocker "AL-06" MEDIUM "Global cluster '$gcid' (PostgreSQL): Cluster Cache Management NOT supported on secondary -- cold buffer pool after failover"
  done < <(echo "$GLOBAL_CLUSTERS" | jq -c '.[]' 2>/dev/null)
  # FT-06 is reported once, in Category 1 (previously duplicated here)
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

  advisory "QT-07" "Concurrent cross-region snapshot copies are limited (5 per destination region) -- multiple simultaneous DR copies queue and delay recovery"

  if [[ "$gc_count"     -ge 5  ]]; then blocker "QT-10" MEDIUM "Aurora Global Databases: $gc_count/5 -- at regional limit."
  else ok "Aurora Global Databases: $gc_count/5"; fi

  # QT-15 (KMS CreateGrant) is covered by KT-04 -- not reported twice

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
  log "  ADVISORY : $ADVISORY_COUNT  (generic, unverifiable from AWS APIs -- not counted in verdict)"
  log ""
  if   [[ "$CRITICAL" -gt 0 ]]; then log "  ${RED}${BOLD}VERDICT: CRITICAL BLOCKERS FOUND -- DR is broken or severely limited${RESET}"
  elif [[ "$HIGH"     -gt 0 ]]; then log "  ${YELLOW}${BOLD}VERDICT: HIGH-SEVERITY BLOCKERS -- DR paths exist but are unreliable${RESET}"
  elif [[ "$MEDIUM"   -gt 0 ]]; then log "  ${CYAN}VERDICT: MEDIUM ISSUES -- DR possible but recovery times degraded${RESET}"
  else                               log "  ${GREEN}${BOLD}VERDICT: No blockers found${RESET}"; fi

  html_summary "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW" "$INFO_COUNT" "$ADVISORY_COUNT"
  html_close
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  html_init
  log "================================================================"
  log "  RBUI -- RDS/Aurora Resilience Blocker Assessment v${RBUI_VERSION}"
  log "  $(date)"
  log "================================================================"

  check_prereqs
  html_meta "$ACCOUNT_ID"
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
