# RBUI — RDS/Aurora Resilience Blocker Assessment Tool

**Version:** 1.0.0  
**Converted from:** https://github.com/aws-samples/sample-kiro-rbui-agent  
**License:** MIT-0

---

## What Is This?

A standalone Linux/macOS shell script that audits your AWS RDS and Aurora
infrastructure for **66 hidden resilience blockers** across 7 categories —
the gap between what AWS documents as possible DR and what is actually
achievable given your current configuration.

No agents, no special runtimes, no Kiro CLI required. Just `aws` + `jq`.

---

## Categories Checked

| # | Category | Blockers | Example |
|---|----------|----------|---------|
| 1 | Failover Timing (FT) | 9 | Aurora single-writer without readers → 10-15 min RTO |
| 2 | Snapshot Restore (SR) | 10 | Lazy loading — "available" ≠ performant |
| 3 | Encryption (EN) | 6 | Unencrypted DB blocks ALL cross-region DR paths |
| 4 | KMS Throttling (KT) | 4 | Parallel encrypted restores share 5,500 req/s quota |
| 5 | Cross-Region DR (CR) | 14 | Version mismatch silently breaks Global Database failover |
| 6 | Application Layer (AL) | 6 | JVM DNS cache can be infinite — never reconnects |
| 7 | Account Quotas (QT) | 20 | Only 5 concurrent cross-region snapshot copies allowed |

Severity levels: **CRITICAL → HIGH → MEDIUM → LOW → INFO**

---

## Prerequisites

### 1. Tools
```bash
# AWS CLI v2
aws --version

# jq (JSON processor)
jq --version

# Install jq if missing:
# Ubuntu/Debian
sudo apt-get install -y jq

# Amazon Linux / RHEL / CentOS
sudo yum install -y jq

# macOS
brew install jq
```

### 2. AWS Credentials
Configure credentials with read-only RDS/KMS permissions:
```bash
aws configure
# or use environment variables:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
# or use an IAM role attached to your EC2/ECS instance
```

### 3. IAM Permissions
Attach the policy in `iam-policy.json` to the IAM user or role running this script.
All permissions are **read-only** — no writes, no changes to your infrastructure.

```bash
# Create the policy in your account
aws iam create-policy \
  --policy-name RBUI-ReadOnly \
  --policy-document file://iam-policy.json
```

---

## Installation

### Option A — Run the installer
```bash
chmod +x install.sh
./install.sh
```
This copies `rbui-check.sh` to `/usr/local/bin/rbui-check` and makes it
executable system-wide.

### Option B — Run directly without installing
```bash
chmod +x rbui-check.sh
./rbui-check.sh us-east-1
```

---

## Usage

```bash
# Assess default region (us-east-1)
rbui-check

# Assess a specific region
rbui-check ca-central-1
rbui-check eu-west-1
rbui-check ap-southeast-1

# Save output to a custom file
rbui-check us-east-1 | tee my-audit.txt

# Run against multiple regions
for region in us-east-1 us-west-2 eu-west-1 ap-southeast-1; do
  echo "=== $region ==="; rbui-check "$region"; done
```

---

## Output

The script produces:
- **Colour-coded terminal output** (CRITICAL=red, HIGH=yellow, MEDIUM=cyan)
- **A timestamped report file** `rbui-report-YYYYMMDD-HHMMSS.txt` in the
  current directory
- **A verdict** at the end with remediation priority (P1/P2/P3)

### Example output snippet
```
══════════════════════════════════════════════
  Category 1: Failover Timing (FT)
══════════════════════════════════════════════
  [CRITICAL] FT-07 — Aurora cluster 'prod-cluster' has NO readers — RTO: 10-15 min
  [HIGH    ] FT-06 — JVM DNS TTL can be INFINITE — Java apps may never reconnect
  [MEDIUM  ] FT-04 — Aurora DNS TTL=5s but client-side caching extends stale routing

══════════════════════════════════════════════
  ASSESSMENT SUMMARY
══════════════════════════════════════════════
  CRITICAL : 2
  HIGH     : 5
  MEDIUM   : 8
  LOW      : 1

  VERDICT: CRITICAL BLOCKERS FOUND — DR is broken or severely limited

  Remediation priority:
    P1 (Immediate) — All CRITICAL items above
    P2 (This week) — All HIGH items above
    P3 (30 days)   — All MEDIUM items above
```

---

## Remediation Priority Guide

| Priority | When | Focus |
|----------|------|-------|
| P1 — Immediate | Today | CRITICAL: FT-07, FT-09, CR-05, QT-03, QT-04, EN-06 |
| P2 — This week | 1-7 days | HIGH: EN-01, EN-04, CR-01, AL-01, AL-02 |
| P3 — 30 days | This month | MEDIUM: SR-05, SR-08, KT-01, CR-14 |

---

## RTO Reference

| Scenario | RTO |
|----------|-----|
| Aurora with readers (normal failover) | 15–30 seconds |
| Multi-AZ single standby | 60–120 seconds |
| Multi-AZ two standbys | < 35 seconds |
| Aurora without readers | 10–15 minutes |
| Snapshot restore < 100 GB | 15–30 minutes |
| Snapshot restore 100–500 GB | 30–60 minutes |
| Snapshot restore > 500 GB | 60–180 minutes |
| Aurora Global DB (planned switchover) | < 1 minute |
| Aurora Global DB (unplanned failover) | 1–2 minutes |

---

## Files in This Package

```
rbui-package/
├── README.md          ← this file
├── rbui-check.sh      ← main assessment script
├── install.sh         ← system-wide installer
├── uninstall.sh       ← removes installed files
└── iam-policy.json    ← read-only IAM policy to attach
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `jq: command not found` | Install jq (see Prerequisites) |
| `aws: command not found` | Install AWS CLI v2 |
| `UnauthorizedOperation` errors | Attach `iam-policy.json` to your IAM identity |
| Empty results | Check `aws configure` and region name |
| `NoCredentialProviders` | Set `AWS_PROFILE` or attach an IAM role |

---

## Security

- All AWS API calls are **read-only** (describe/list/get only)
- No data is sent anywhere outside your AWS account
- No credentials are stored or logged by the script
- Safe to run in production environments

---

*Based on the RBUI agent: https://github.com/aws-samples/sample-kiro-rbui-agent*
