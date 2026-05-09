output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "alb_url" {
  description = "Full HTTPS URL of the API"
  value       = "https://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL for pushing the Docker image"
  value       = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  description = "RDS endpoint hostname (private, only reachable from ECS)"
  value       = aws_db_instance.main.address
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
}

output "secret_arn" {
  description = "ARN of the database secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db.arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN assumed by GitHub Actions via OIDC for deploy"
  value       = aws_iam_role.github_actions.arn
}
