# RBUI — RDS/Aurora Resilience Blocker Assessment Tool

**Version:** 1.3.2  
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

Severity levels: **CRITICAL → HIGH → MEDIUM → LOW → INFO**, plus **ADVISORY**.

- **CRITICAL / HIGH / MEDIUM / LOW / INFO** — derived from your account data
  (describe/list API output, measured DNS TTLs, KMS key metadata). These are
  counted in the verdict and include the evidence that triggered them.
- **ADVISORY** — generic best-practice reminders the script **cannot verify**
  from AWS APIs (JVM DNS cache, connection pools, TCP keepalive, KMS quota
  contention, restore behaviour). Not counted in the verdict — verify manually.

---

## Prerequisites

### 1. Tools
```bash
# AWS CLI v2
aws --version

# jq (JSON processor)
jq --version
# dig (optional) -- measures endpoint DNS TTLs for FT-04/FT-05.
# Without it those checks are reported as ADVISORY (not measured).
dig -v   # Amazon Linux: sudo yum install -y bind-utils

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

> ⚠️ **Upgrading from v1.3.0 or earlier — update the IAM policy in AWS.**
> v1.3.1+ also needs `service-quotas:ListAWSDefaultServiceQuotas` (already in
> `iam-policy.json`). Pulling the new code does **not** change the policy that
> is attached in your account — publish a new version of it:
>
> ```bash
> aws iam create-policy-version \
>   --policy-arn arn:aws:iam::ACCOUNT_ID:policy/RBUI-ReadOnly \
>   --policy-document file://iam-policy.json \
>   --set-as-default
> ```
>
> IAM keeps at most 5 versions per policy. If the command fails with
> `LimitExceeded`, remove an old one first:
> `aws iam list-policy-versions --policy-arn ...` then
> `aws iam delete-policy-version --policy-arn ... --version-id v1`.
> Without this permission the script still runs, but quota limits it cannot
> read are reported as `UNVERIFIED default`.

---

## Installation

### Get the code
```bash
# First time
git clone https://github.com/belmacanik-ctrl/rbui-assessment.git rbui-package
cd rbui-package

# Upgrade an existing clone
git -C rbui-package pull
```
Alternatively, unzip the release package `rbui-assessment-vX.Y.Z.zip` from
this repo (it contains the same files under `rbui-package/`). If your
`rbui-package/` folder came from a zip, it is not a git repo — remove it and
clone instead of pulling.

After upgrading, re-run `./install.sh` (the installed copy in
`/usr/local/bin` is not updated automatically) and check the
**IAM policy upgrade note** above.

### Option A — Run the installer
```bash
chmod +x install.sh
./install.sh
grep -m1 '^RBUI_VERSION=' /usr/local/bin/rbui-check   # confirm installed version
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

# Assess a region AND verify KMS readiness in a target DR region (EN-03)
rbui-check eu-west-1 eu-central-1
# (equivalent: RBUI_DR_REGION=eu-central-1 rbui-check eu-west-1)
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
- **A timestamped HTML report** `rbui-report-YYYYMMDD-HHMMSS.html` in the
  current directory
- **A verdict** at the end with remediation priority (P1/P2/P3)

### Example output snippet
```
══════════════════════════════════════════════
  Category 1: Failover Timing (FT)
══════════════════════════════════════════════
  [CRITICAL] FT-07 -- Aurora cluster 'prod' (aurora-postgresql): NO readers -- members: prod-1 (writer, eu-west-1a). ...
  [MEDIUM  ] FT-05 -- RDS instance 'db1': endpoint DNS TTL measured at 60s (...)
  [ADVISORY] FT-06 -- Java clients: JVM DNS caching is INFINITE only when a SecurityManager is installed ...

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
| P2 — This week | 1-7 days | HIGH: FT-10, EN-01, EN-03 (DR key missing), EN-05 (aws/rds key), CR-01, AL-01 |
| P3 — 30 days | This month | MEDIUM: FT-04/FT-05 (measured TTL), SR-05, CR-14 |
| Review | Any time | ADVISORY items — verify manually, not counted |

## Changelog

**1.3.2** (packaging/docs — no assessment logic changes)
- README + installer: IAM policy upgrade steps (`create-policy-version`) for
  the `service-quotas:ListAWSDefaultServiceQuotas` permission added in 1.3.1.
- README: install/upgrade via `git clone` / `git pull`, troubleshooting for
  UNVERIFIED quotas, missing `dig`, KMS DescribeKey, stale installed copy.
- install.sh: shows the real script version, checks for optional `dig`,
  verifies the installed version, DR-region usage example.
- uninstall.sh: cleans up `.html` reports (was only `.txt`), and no longer
  aborts silently before "Uninstall complete" when no report files exist.
- `.gitignore` for `.DS_Store` and generated reports; `.DS_Store` untracked.

**1.3.1**
- Category 7 (QT) now uses your account's real limits instead of hard-coded
  defaults. Resolution order: `rds describe-account-attributes` (real Used +
  Max) -> Service Quotas applied value -> Service Quotas AWS default ->
  hard-coded default. Every line shows where the limit came from; a limit that
  is only an assumed default is reported as ADVISORY ("UNVERIFIED default"),
  never as OK. Thresholds are 90% of the real limit.
- KT-01 / KT-04 read the KMS "Cryptographic operations (symmetric) request
  rate" and "CreateGrant request rate" quotas by name. The previous quota code
  returned an unrelated 1,000 req/s value, and failures silently fell back to
  5,500.
- IAM policy: added `service-quotas:ListAWSDefaultServiceQuotas`.

**1.3.0**
- New `ADVISORY` severity for generic, unverifiable items (FT-03, FT-06, KT-*,
  SR-01/03/06/07/08, AL-02/03, QT-07); excluded from the verdict.
- FT-03/FT-05 only for Multi-AZ non-Aurora instances; FT-05/FT-04 now measure
  endpoint DNS TTL with `dig` instead of hard-coded values.
- FT-06 reported once (was duplicated in Category 6); wording corrected
  (infinite caching only with a SecurityManager).
- FT-07 shows member/role/AZ evidence; no longer infers Aurora readers from
  `ReadReplicaSourceDBInstanceIdentifier` (false CRITICALs). New FT-10: all
  readers in the writer's AZ.
- EN-03/EN-05 resolve the key via `kms:DescribeKey` (the old `aws/rds` string
  match never matched a key ARN). AWS-managed key -> EN-05 HIGH. Optional DR
  region argument checks CMK / multi-Region replica readiness. EN-01/EN-04
  merged into one finding with accurate wording.
- Fixed: account/region header lines were swallowed into a variable and bad
  credentials didn't stop the run; API warnings corrupted collected JSON;
  failed `describe-db-proxies` produced false "NO RDS Proxy" findings;
  `describe-global-clusters` ignored the region argument; QT-15 duplicated KT-04;
  SR-10 no longer uses Aurora's placeholder `AllocatedStorage`.

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
├── uninstall.sh       ← removes installed files (and optionally reports)
├── iam-policy.json    ← read-only IAM policy to attach
└── rbui-assessment-vX.Y.Z.zip  ← release package of the files above
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
| `[WARN] list-aws-default-service-quotas ... AccessDenied` / quotas shown as `UNVERIFIED default` | Update the IAM policy in AWS (see **IAM policy upgrade note**) |
| `[WARN] 'dig' not found` / FT-04, FT-05 shown as ADVISORY | Install `bind-utils` (Amazon Linux/RHEL) or `dnsutils` (Debian/Ubuntu) |
| EN-05 `could not describe KMS key` | Grant `kms:DescribeKey` (in `iam-policy.json`); keys in another account can't be described |
| Old version still runs after `git pull` | Re-run `./install.sh` — `/usr/local/bin/rbui-check` is a copy |
| `git pull` fails: not a git repository | Folder came from a zip — remove it and `git clone` |

---

## Security

- All AWS API calls are **read-only** (describe/list/get only)
- No data is sent anywhere outside your AWS account
- No credentials are stored or logged by the script
- Safe to run in production environments

---

*Based on the RBUI agent: https://github.com/aws-samples/sample-kiro-rbui-agent*
