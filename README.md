# SafeTrace — Task 1 deployment (AWS CLI)

Provisions the **serverful** stack entirely with the AWS CLI — no console
click-ops and no hand-written CloudFormation.

```
Browser → ALB (HTTP 80) → EC2 Auto Scaling Group (2 AZs)
        → Docker Compose (Next.js :80 + Express :5000) → RDS PostgreSQL (private)
Secrets Manager → app config   |   CloudWatch → metrics & logs
```

## Prerequisites

- AWS CLI v2 installed and `aws configure` done (or env credentials).
- Your repository pushed to GitHub (the instances `git clone` it on boot).

## Usage

```bash
cd infra/server

# 1. Configure
export DB_PASSWORD='ChangeMe-strong-pw'      # required (avoid / @ " space)
export REPO_URL='https://github.com/<you>/<repo>.git'
#   ...or edit config.env directly. Optional knobs: USE_PUBLIC_INSTANCES=true
#   (skip the paid NAT gateway), INSTANCE_TYPE, DB_INSTANCE_CLASS, ASG_* etc.

# 2. Deploy (idempotent — safe to re-run)
./deploy.sh

# 3. When done, remove everything
./teardown.sh
```

`deploy.sh` prints the ALB URL. The first boot builds Docker images, so targets
take a few minutes to become healthy. Then:

```bash
curl -X POST http://<alb-dns>/api/admin/seed     # demo data
open http://<alb-dns>                            # the app
```

## What it creates

| Step | Resource |
|---|---|
| Network | VPC, 2 public + 2 private subnets (2 AZs), IGW, NAT GW, route tables |
| Security | 3 chained security groups (internet → ALB → EC2 → RDS) |
| Secrets | `safetrace/prod/app` (DATABASE_URL, JWT_SECRET, FRONTEND_PUBLIC_URL, …) |
| Data | RDS PostgreSQL (private, not publicly accessible) |
| IAM | EC2 role + instance profile, least-privilege read of the one secret |
| Compute | Launch template (Ubuntu 24.04, IMDSv2), Target group, ALB, Auto Scaling group with CPU target-tracking |

Created resource ids are saved to `.state.env` (git-ignored) so `teardown.sh`
can delete them in the right order.

> Costs: a NAT gateway, ALB, RDS and 2 EC2 instances accrue charges. Run
> `./teardown.sh` after capturing your evidence. Set `USE_PUBLIC_INSTANCES=true`
> to skip the NAT gateway for a cheaper lab run.
