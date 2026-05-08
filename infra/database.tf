# Random password for the RDS master user
resource "random_password" "db_password" {
  length  = 24
  special = true
  # RDS forbids these characters in passwords
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

# Subnet group: tells RDS which subnets it can live in
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# RDS PostgreSQL instance
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.micro"

  allow_major_version_upgrade = true
  allocated_storage           = 20
  max_allocated_storage       = 50
  storage_type                = "gp3"
  storage_encrypted           = true

  db_name  = "banking"
  username = var.db_username
  password = random_password.db_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name = "${var.project_name}-db"
  }
}

# Store database connection details in Secrets Manager
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}-db-credentials"
  description             = "RDS credentials for banking-api"
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username     = aws_db_instance.main.username
    password     = aws_db_instance.main.password
    host         = aws_db_instance.main.address
    port         = aws_db_instance.main.port
    database     = aws_db_instance.main.db_name
    DATABASE_URL = "postgresql://${aws_db_instance.main.username}:${random_password.db_password.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}"
  })
}
