# Banking API

A REST API for basic banking operations (account creation, balance enquiry, deposits, withdrawals) built as a take-home exercise. Deployed to AWS Singapore (ap-southeast-1) with full Infrastructure-as-Code and CI/CD.

## Architecture

![Architecture](docs/architecture.png)

## Tech Stack

- **Application:** FastAPI (Python 3.11), SQLAlchemy, Alembic, psycopg2
- **Database:** PostgreSQL 15 (Amazon RDS)
- **Container:** Docker, Amazon ECR
- **Compute:** Amazon ECS on Fargate
- **Networking:** VPC with public/private subnets, Application Load Balancer, NAT Gateway
- **Secrets:** AWS Secrets Manager
- **Monitoring:** CloudWatch (logs, dashboard, alarm)
- **Infrastructure:** Terraform
- **CI/CD:** GitHub Actions with OIDC (no long-lived AWS keys)

## Live Endpoint

https://banking-api-alb-1168095763.ap-southeast-1.elb.amazonaws.com

HTTPS uses a self-signed certificate (no domain). Use `curl -k` or browser override.

## Setup Guide

This is a step-by-step walkthrough from fresh clone to deployed application. Existing infrastructure is already deployed; these steps document how to recreate it from scratch.

### Prerequisites

Install on your local machine:

- **AWS CLI v2** — https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- **Terraform 1.6+** — https://developer.hashicorp.com/terraform/install
- **Docker Desktop** (Windows/Mac) or Docker Engine (Linux)
- **Python 3.11+**
- **Git**

### AWS Account Setup

1. Create or use an existing AWS account.
2. Create an IAM user (or use an existing one) with **AdministratorAccess** for the initial Terraform apply. After deployment you can scope this down — see Trade-offs.
3. Generate an access key for that user, then run:
```bash
   aws configure
```
   Enter the access key, secret, region `ap-southeast-1`, and output format `json`.

### Step 1: Clone the Repository

```bash
git clone https://github.com/nidhinbose89/banking-api.git
cd banking-api
```

### Step 2: Deploy Infrastructure

```bash
cd infra
terraform init
terraform apply
```

Review the plan and type `yes` when prompted. Takes ~10 minutes (RDS is the slowest).

When done, note the outputs:

- `alb_url` — the live application endpoint
- `ecr_repository_url` — where the Docker image will be pushed
- `github_actions_role_arn` — for CI/CD setup (next step)

### Step 3: Configure GitHub Actions for AWS

GitHub Actions authenticates to AWS via OpenID Connect (OIDC), so no AWS keys are stored as secrets. The Terraform apply already created the IAM role and trust policy.

The deploy workflow reads the IAM role ARN from a GitHub Actions variable (`AWS_DEPLOY_ROLE_ARN`), so the workflow file works for any AWS account without code changes.

If forking this repo into your own AWS account:

1. Update the IAM role's trust policy in `infra/iam_github_actions.tf` to reference your fork (`repo:YOUR_USERNAME/YOUR_REPO:ref:refs/heads/main`), then re-apply Terraform.
2. In your fork's GitHub repo: **Settings → Secrets and variables → Actions → Variables tab → New repository variable**. Name it `AWS_DEPLOY_ROLE_ARN`, value is the `github_actions_role_arn` output from `terraform apply`.

### Step 4: First Deployment (manual, before CI/CD takes over)

The first Docker image needs to be pushed manually so ECS has something to run.

```bash
# From repo root
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin $(terraform -chdir=infra output -raw ecr_repository_url)

docker build -t banking-api:latest .
docker tag banking-api:latest $(terraform -chdir=infra output -raw ecr_repository_url):latest
docker push $(terraform -chdir=infra output -raw ecr_repository_url):latest

aws ecs update-service \
  --cluster banking-api-cluster \
  --service banking-api-service \
  --force-new-deployment \
  --region ap-southeast-1
```

Wait ~3 minutes for ECS to pull the image and start tasks.

### Step 5: Verify Deployment

```bash
curl -k $(terraform -chdir=infra output -raw alb_url)/health
```

Expected: `{"status":"ok"}`

Or run the full smoke test (see Smoke Test section below).

### Step 6: Subsequent Deployments via CI/CD

After Step 4, every push to the `main` branch automatically:

1. Runs pytest in a Postgres service container
2. Builds a new Docker image, tags with commit SHA + `latest`
3. Pushes to ECR
4. Forces ECS to deploy the new image
5. Waits for the service to stabilize

Pull requests run only the test job.

### Tearing Down

```bash
cd infra
terraform destroy
```

This removes all AWS resources created by Terraform. ECR images and CloudWatch log retention are also deleted.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/accounts` | Create a new account |
| GET | `/accounts/{id}/balance` | Get current balance |
| POST | `/accounts/{id}/deposit` | Deposit funds (requires `Idempotency-Key` header) |
| POST | `/accounts/{id}/withdraw` | Withdraw funds (requires `Idempotency-Key` header) |
| GET | `/health` | Liveness check |
| GET | `/version` | Returns deployed commit SHA and build timestamp |

Full OpenAPI docs at `/docs` on the live URL.

### Idempotency

Deposit and withdraw require an `Idempotency-Key` header. Replaying the same key with the same body returns the original response. Replaying with a different body returns 422 (key reused with different payload). This prevents duplicate transactions on client retries.

## Local Development

Requires Docker and Docker Compose.

```bash
cp .env.example .env
docker compose up --build
```

App available at `http://localhost:8000`. Swagger UI at `http://localhost:8000/docs`.

For a full local Python environment (runtime, tests, and diagram tooling):

```bash
pip install -r requirements-dev.txt
```

## Running Tests

Tests are integration tests against a real Postgres (see Trade-offs).

```bash
pip install -r requirements-test.txt
docker compose up -d db
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres pytest
```

In CI, GitHub Actions provides a throwaway Postgres service container.

## Smoke Test

After deployment, run the smoke test against the live API (uses `curl -k` / certificate skip for the self-signed ALB cert):

```bash
chmod +x scripts/smoke_test.sh
./scripts/smoke_test.sh
```

Or on Windows (Windows PowerShell 5.1 or PowerShell 7+):

```powershell
.\scripts\smoke_test.ps1
```

Optional first argument is the API base URL; it defaults to the live ALB URL in the scripts.

The Bash script uses `jq` if installed for JSON replay checks; install `jq` for the most reliable output (`apt install jq`, `brew install jq`, etc.). The PowerShell script uses `Invoke-WebRequest` (with certificate skip appropriate to the PowerShell version). The script exercises all endpoints, including idempotency edge cases. Exits non-zero on any failure.

## Deployment

Continuous deployment via GitHub Actions. Full setup steps in [Setup Guide](#setup-guide). Summary:

- **Test job:** runs pytest against a Postgres service container (also on PRs).
- **Deploy job:** assumes an AWS IAM role via OpenID Connect (no long-lived keys), builds the Docker image, tags with commit SHA and `latest`, pushes to ECR, forces ECS deployment, waits for service to stabilize.

Image tagging: every image is pushed with the 7-character git commit SHA (e.g. `a3f9c21`) for traceability and `latest` for ECS task definition reference. Rollback is done by retagging an older SHA as `latest`.

## Infrastructure

All AWS resources are defined in `infra/` as Terraform. Resources include:

- VPC with public and private subnets across 2 Availability Zones
- Application Load Balancer (HTTPS:443 with self-signed cert, HTTP:80 redirects)
- ECS cluster, task definition (0.25 vCPU, 512 MB), service (2 tasks)
- RDS PostgreSQL 15 (db.t3.micro, single-AZ)
- ECR repository with scan-on-push and lifecycle policy (keep last 10 images)
- Secrets Manager for the database connection string
- CloudWatch log group, dashboard, and 5xx error alarm
- IAM OpenID Connect provider and role for GitHub Actions

Setup commands are in the [Setup Guide](#setup-guide).

## Monitoring

- **Logs:** CloudWatch log group `/ecs/banking-api`, streamed from all containers.
- **Dashboard:** https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=banking-api-dashboard (4 widgets: ALB request count, ALB 5xx errors, ECS CPU, ECS memory)
- **Alarm:** `banking-api-alb-5xx-errors` triggers when 5xx target errors exceed 5 in 5 minutes.

## Security

### Network Isolation
- VPC with public and private subnets across 2 Availability Zones.
- ALB in public subnets, ECS tasks and RDS in private subnets.
- NAT Gateway for outbound-only egress from private subnets.
- Security groups enforce least-privilege flow:
  - ALB accepts 443/80 from the internet only.
  - ECS tasks accept 8000 from the ALB security group only.
  - RDS accepts 5432 from the ECS security group only.

### Encryption
- **In transit:** HTTPS:443 at the ALB, HTTP:80 redirects to HTTPS. Self-signed certificate (no domain).
- **At rest:** RDS storage encrypted (AWS-managed KMS key). Secrets Manager values encrypted by default.

### Access Control
- IAM roles follow least-privilege:
  - ECS task execution role: pull from ECR, write to CloudWatch, read the specific DB secret only.
  - ECS task role: minimal application-level permissions.
  - GitHub Actions role: ECR push, ECS update-service, PassRole on the task execution role only.
- GitHub Actions authenticates via OpenID Connect. No long-lived AWS access keys are stored as GitHub Secrets.
- The OIDC trust policy is scoped to this specific repository and the `main` branch.

### Secrets Management
- Database credentials are generated by Terraform and stored in AWS Secrets Manager.
- ECS injects the connection string into the container at startup. Credentials never appear in source code, environment files, or CloudWatch logs.

### Application-Level Safeguards
- `Idempotency-Key` header on deposit and withdraw prevents duplicate transactions on client retries.
- Pydantic schema validation rejects malformed input before reaching business logic.
- `SELECT FOR UPDATE` row locking on balance reads prevents race conditions on concurrent withdrawals.

## Trade-offs and Design Decisions

These are choices I'd revisit in a production environment with more time:

- **Self-signed TLS certificate.** No domain was registered for this exercise. Production would use AWS Certificate Manager with a real domain.
- **Integration tests only.** The current tests hit a real Postgres database. In production I would split into unit tests (mocked dependencies, run on every commit) and integration tests (real DB, run in CI). Skipped for time.
- **Shared `DATABASE_URL` for app and tests.** Both read the same environment variable. The test fixture explicitly switches to a `banking_test` database to avoid touching production data, but a separate `TEST_DATABASE_URL` would make this safer.
- **Single environment.** No staging/production split. A real setup would have separate AWS accounts or at least separate Terraform workspaces with promotion between them.
- **Smoke test writes to the live database.** Each run creates a real account and transactions in production RDS. Production would use a dedicated synthetic test account, run smoke tests against staging only, or auto-clean up after each run.
- **No application performance monitoring.** CloudWatch covers infrastructure metrics. AWS X-Ray or DataDog would give per-request tracing.
- **No image vulnerability scanning beyond ECR scan-on-push.** Adding Trivy or Snyk in the CI pipeline would catch issues before push.
- **No deploy approval gate.** Pushes to main deploy automatically. Production would gate behind GitHub Environments approval or a manual promotion step.
- **`db.t3.micro` and 0.25 vCPU Fargate.** Smallest valid sizes, suitable for demo. Production sizing would come from load testing.

## Repository Layout

```
.
├── app/                    # FastAPI application
├── alembic/                # Database migrations
├── tests/                  # Integration tests
├── infra/                  # Terraform IaC
├── docs/                   # Architecture diagram (source + PNG)
├── .github/workflows/      # CI/CD pipeline
├── scripts/                # Smoke tests (bash + PowerShell)
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── requirements-test.txt
├── requirements-dev.txt
└── README.md
```