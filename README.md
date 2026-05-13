# Banking API

REST API for basic banking (accounts, balance, deposits, withdrawals) — take-home exercise with Terraform on AWS (`ap-southeast-1`) and GitHub Actions (OIDC, no long-lived AWS keys in GitHub).

The **reference AWS environment for this repo is not running** (stack torn down). There is no public URL unless you deploy from `infra/`. Use [Local development](#local-development) to run the app on your machine, or follow the [Setup guide](#setup-guide) to provision your own account.

## Architecture

![Architecture](docs/architecture.png)

## Tech stack

- **App:** FastAPI (Python 3.11), SQLAlchemy, Alembic, psycopg2
- **DB:** PostgreSQL 15 (RDS when deployed)
- **Runtime:** Docker → ECR → ECS Fargate
- **Network:** VPC (public/private subnets), ALB, NAT
- **Secrets:** AWS Secrets Manager
- **Observability:** CloudWatch (logs, dashboard, alarm)
- **IaC / CI:** Terraform, GitHub Actions

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | API metadata and links |
| POST | `/accounts` | Create account |
| GET | `/accounts/{id}/balance` | Current balance |
| POST | `/accounts/{id}/deposit` | Deposit (`Idempotency-Key` required) |
| POST | `/accounts/{id}/withdraw` | Withdraw (`Idempotency-Key` required) |
| GET | `/health` | Liveness |
| GET | `/version` | Build metadata |

OpenAPI: `/docs` on your host (e.g. `http://localhost:8000/docs` locally, or `https://<alb>/docs` after deploy). Deployed ALB uses a **self-signed** TLS cert — use `curl -k`, `curl.exe -k`, or skip cert verification in your client.

### Idempotency

Deposits and withdrawals require `Idempotency-Key`. Same key + same body → same response. Same key + different body → `422`.

## Local development

Docker Compose:

```bash
cp .env.example .env
docker compose up --build
```

App: `http://localhost:8000` · Swagger: `http://localhost:8000/docs`

Optional local toolchain (tests, diagrams):

```bash
pip install -r requirements-dev.txt
```

## Running tests

Integration tests against real Postgres (see [Trade-offs](#trade-offs-and-design-decisions)).

```bash
pip install -r requirements-test.txt
docker compose up -d db
```

**Bash:**

```bash
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres pytest
```

**PowerShell:**

```powershell
$env:DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/postgres"
pytest
```

CI uses a disposable Postgres service container.

## Smoke test

Scripts: `scripts/smoke_test.sh` (Bash + `curl`) and `scripts/smoke_test.ps1` (Windows PowerShell 5.1+). They hit **whatever base URL you pass**; do not rely on the baked-in default in source (it may point at an old host).

**Bash**

```bash
chmod +x scripts/smoke_test.sh
./scripts/smoke_test.sh "https://YOUR_ALB_HOST"
```

**PowerShell**

```powershell
.\scripts\smoke_test.ps1 "https://YOUR_ALB_HOST"
```

After Terraform apply, substitute `YOUR_ALB_HOST` from `alb_url` (no trailing slash), e.g.:

```bash
./scripts/smoke_test.sh "$(terraform -chdir=infra output -raw alb_url)"
```

```powershell
$url = terraform -chdir=infra output -raw alb_url
.\scripts\smoke_test.ps1 $url
```

`jq` improves JSON assertions in the shell script (`apt install jq`, `brew install jq`, …). Non-zero exit on any failed check.

## Setup guide

End-to-end: clone → Terraform → first image → ECS. Nothing exists in AWS until `terraform apply` in `infra/`.

### Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Terraform 1.6+](https://developer.hashicorp.com/terraform/install)
- Docker
- Python 3.11+
- Git

### AWS account setup

1. AWS account and IAM identity with enough rights for first apply (see trade-offs for tightening later).
2. `aws configure` — access key, secret, region `ap-southeast-1`, output `json`.

### Forking (own GitHub repo + AWS)

If the GitHub repo slug differs from the default in Terraform, set variable **`github_repository`** (`owner/name`) **before** the apply that creates the OIDC role, e.g.:

```bash
terraform apply -var="github_repository=YOUR_ORG/YOUR_REPO"
```

or `infra/terraform.tfvars`:

```
github_repository = "YOUR_ORG/YOUR_REPO"
```

Variable lives in `infra/variables.tf`; trust policy uses it in `infra/iam_github_actions.tf`.

### Step 1 — Clone

```bash
git clone https://github.com/nidhinbose89/banking-api.git
cd banking-api
```

### Step 2 — Terraform

```bash
cd infra
terraform init
terraform apply
```

Confirm the plan (`yes`). Budget ~10 minutes (RDS is slowest). Note outputs: `alb_url`, `ecr_repository_url`, `github_actions_role_arn`.

### Step 3 — GitHub Actions variable

Workflow assumes AWS with OIDC via repository variable **`AWS_DEPLOY_ROLE_ARN`**.

GitHub → **Settings** → **Secrets and variables** → **Actions** → **Variables** → **New repository variable**: name `AWS_DEPLOY_ROLE_ARN`, value = `github_actions_role_arn` from Step 2.

### Step 4 — First image (before CI pushes)

From repo root.

**Bash**

```bash
ECR_URL=$(terraform -chdir=infra output -raw ecr_repository_url)

aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin "$ECR_URL"

docker build -t banking-api:latest .
docker tag banking-api:latest "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"

aws ecs update-service \
  --cluster banking-api-cluster \
  --service banking-api-service \
  --force-new-deployment \
  --region ap-southeast-1
```

**PowerShell**

```powershell
$ecrUrl = terraform -chdir=infra output -raw ecr_repository_url
$ecrPassword = aws ecr get-login-password --region ap-southeast-1
$ecrPassword | docker login --username AWS --password-stdin $ecrUrl

docker build -t banking-api:latest .
docker tag banking-api:latest "${ecrUrl}:latest"
docker push "${ecrUrl}:latest"

aws ecs update-service `
  --cluster banking-api-cluster `
  --service banking-api-service `
  --force-new-deployment `
  --region ap-southeast-1
```

Wait a few minutes for ECS to stabilize.

### Step 5 — Verify

Use [Smoke test](#smoke-test) against `alb_url`.

### Step 6 — Ongoing deploys

Pushes to `main`: tests (with Postgres service) → build → push ECR (`<sha>` + `latest`) → ECS rolling update. PRs: tests only.

### Health check (optional)

**Bash**

```bash
curl -k "$(terraform -chdir=infra output -raw alb_url)/health"
```

**PowerShell**

```powershell
$base = terraform -chdir=infra output -raw alb_url
curl.exe -k "$base/health"
```

### Tear down

```bash
cd infra
terraform destroy
```

Removes Terraform-managed resources (including ECR with `force_delete` where configured).

## Deployment (CI/CD)

Details in [Setup guide](#setup-guide). Short version:

- **test** — `pytest` + Postgres (runs on PRs too).
- **deploy** — OIDC to AWS, Docker build, tag SHA + `latest`, ECR push, `ecs update-service`, wait stable.

Rollback: retag an older image as `latest` in ECR and redeploy.

## Infrastructure (Terraform)

Under `infra/`: VPC (2 AZs), public/private subnets, ALB (HTTPS self-signed, HTTP→HTTPS), ECS Fargate service, RDS Postgres 15, ECR (+ lifecycle), Secrets Manager, CloudWatch (logs, dashboard, 5xx alarm), GitHub OIDC provider + deploy role.

## Monitoring

With the stack applied: logs in `/ecs/banking-api`; dashboard **`banking-api-dashboard`** in CloudWatch; alarm **`banking-api-alb-5xx-errors`** (5xx threshold over 5 minutes). Destroy removes them.

## Security

Applies **while the stack exists** (not after destroy).

### Network

Private subnets for ECS and RDS; ALB public; NAT for egress. SGs: internet → ALB `:443`/`:80`; ALB → ECS `:8000`; ECS → RDS `:5432`.

### Encryption

TLS at ALB (self-signed demo cert). RDS and Secrets Manager encrypted at rest (defaults / AWS-managed keys).

### IAM

Task execution: ECR pull, logs, read DB secret. Task role: app scope. GitHub role: ECR push, ECS service update, `PassRole` for execution role. OIDC in GitHub — no static AWS keys in repo secrets. Trust subject matches `github_repository` and `main` (see Terraform).

### Secrets

DB URL from Terraform → Secrets Manager → injected into task. Not committed to git.

### Application

Idempotency keys; Pydantic validation; `SELECT FOR UPDATE` on balance path for concurrent withdrawals.

## Trade-offs and design decisions

- Self-signed ALB cert — production would use ACM + real DNS.
- Heavy integration tests against Postgres — would split unit vs integration in production.
- Same `DATABASE_URL` pattern for app/tests locally — tests use a separate DB name where configured; `TEST_DATABASE_URL` would be clearer.
- Single env — no staged promotion story.
- Smoke tests against a real DB when aimed at cloud — use staging or cleanup in production.
- No APM beyond CloudWatch — would add tracing in production.
- ECR scan only — would add Trivy/Snyk in CI for stronger gates.
- Direct deploy from `main` — would add approvals / environments.
- Small RDS + Fargate SKU — demo sizing only.

## Repository layout

```
.
├── app/
├── alembic/
├── tests/
├── infra/
├── docs/
├── .github/workflows/
├── scripts/
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── requirements-test.txt
├── requirements-dev.txt
└── README.md
```
