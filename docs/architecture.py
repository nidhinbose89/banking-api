# Run: python docs/architecture.py  (requires graphviz installed: brew install graphviz / apt install graphviz / choco install graphviz)
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECS, ECR, Fargate
from diagrams.aws.database import RDS
from diagrams.aws.devtools import Codebuild
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import ALB, InternetGateway, NATGateway
from diagrams.aws.security import SecretsManager
from diagrams.onprem.vcs import Github

with Diagram(
    "Banking API - AWS Architecture (ap-southeast-1)",
    filename="docs/architecture",
    outformat="png",
    show=False,
):
    internet = InternetGateway("Internet")
    github = Github("GitHub Actions")
    ecr = ECR("ECR")
    cloudwatch = Cloudwatch("CloudWatch Logs")
    secrets = SecretsManager("Secrets Manager")
    ecr_placeholder = Codebuild("CI/CD Build")

    with Cluster("VPC"):
        with Cluster("Public Subnets (AZ-a, AZ-b)"):
            alb = ALB("Application Load Balancer")
            nat = NATGateway("NAT Gateway")

        with Cluster("Private Subnets (AZ-a, AZ-b)"):
            ecs_service = ECS("ECS Service")
            tasks = Fargate("Fargate (2 tasks)")
            rds = RDS("RDS Postgres")

            ecs_service >> tasks

    internet >> Edge(label="HTTPS:443") >> alb
    alb >> Edge(label="HTTP:8000") >> tasks
    tasks >> Edge(label="5432") >> rds
    tasks >> Edge(label="fetch DB creds") >> secrets
    tasks >> Edge(label="logs") >> cloudwatch
    tasks >> nat >> internet

    github >> Edge(label="docker push") >> ecr
    github >> Edge(label="force-new-deployment") >> ecs_service
    github >> ecr_placeholder
