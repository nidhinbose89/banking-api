# Trust policy: allows ECS tasks to assume these roles
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ECS Task Execution Role: used by ECS itself to start the container
# (pull image from ECR, fetch secrets, write logs)
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = {
    Name = "${var.project_name}-ecs-task-execution"
  }
}

# Attach AWS managed policy for basic ECS execution permissions
# (ECR pull, CloudWatch Logs write)
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow execution role to read the database secret from Secrets Manager
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name = "read-db-secret"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db.arn
      }
    ]
  })
}

# ECS Task Role: assumed by the running application container itself
# (used for any AWS calls the app code makes at runtime)
resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = {
    Name = "${var.project_name}-ecs-task"
  }
}
