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

## Running Tests

Tests are integration tests against a real Postgres (see Trade-offs).

```bash
docker compose up -d db
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres pytest
```

In CI, GitHub Actions provides a throwaway Postgres service container.

## Deployment

Pushes to `main` trigger `.github/workflows/deploy.yml`:

1. **Test job:** runs pytest against a Postgres service container.
2. **Deploy job:** assumes an AWS IAM role via OIDC (no long-lived keys), builds the Docker image, tags it with the git commit SHA and `latest`, pushes to ECR, forces a new ECS deployment, and waits for the service to stabilize.

Pull requests run only the test job.

### Authentication

GitHub Actions authenticates to AWS using OpenID Connect (OIDC). The IAM role's trust policy is scoped to this specific repository and the `main` branch. No AWS access keys are stored in GitHub Secrets.

### Image Tagging

Every image is pushed with two tags:
- The 7-character git commit SHA (e.g. `a3f9c21`) for traceability.
- `latest` for the ECS task definition reference.

This allows rollback by retagging an older SHA as `latest`.

## Infrastructure

All infrastructure is defined in `infra/` as Terraform. Resources include:

- VPC with public and private subnets across 2 Availability Zones
- Application Load Balancer (HTTPS:443 with self-signed cert, HTTP:80 redirects)
- ECS cluster, task definition (0.25 vCPU, 512 MB), and service (2 tasks)
- RDS PostgreSQL 15 (db.t3.micro, single-AZ)
- ECR repository with scan-on-push and lifecycle policy (keep last 10 images)
- Secrets Manager for the database connection string
- CloudWatch log group, dashboard, and 5xx error alarm
- IAM OIDC provider and role for GitHub Actions

To deploy:

```bash
cd infra
terraform init
terraform apply
```

## Monitoring

- **Logs:** CloudWatch log group `/ecs/banking-api`, streamed from all containers.
- **Dashboard:** https://ap-southeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-southeast-1#dashboards:name=banking-api-dashboard (4 widgets: ALB request count, ALB 5xx errors, ECS CPU, ECS memory)
- **Alarm:** `banking-api-alb-5xx-errors` triggers when 5xx target errors exceed 5 in 5 minutes.

## Trade-offs and Design Decisions

These are choices I'd revisit in a production environment with more time:

- **Self-signed TLS certificate.** No domain was registered for this exercise. Production would use AWS Certificate Manager with a real domain.
- **Integration tests only.** The current tests hit a real Postgres database. In production I would split into unit tests (mocked dependencies, run on every commit) and integration tests (real DB, run in CI). Skipped for time.
- **Shared `DATABASE_URL` for app and tests.** Both read the same environment variable. The test fixture explicitly switches to a `banking_test` database to avoid touching production data, but a separate `TEST_DATABASE_URL` would make this safer.
- **Single environment.** No staging/production split. A real setup would have separate AWS accounts or at least separate Terraform workspaces with promotion between them.
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
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── requirements-dev.txt
└── README.md
```