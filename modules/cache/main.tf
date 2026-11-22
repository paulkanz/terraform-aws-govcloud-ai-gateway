resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-cache-subnet"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project}-${var.environment}-cache-subnet"
  }
}

resource "random_uuid" "redis_password" {}

resource "aws_ssm_parameter" "redis_password" {
  name        = "/ecs/enterprise-app/${var.environment}/REDIS_PASSWORD"
  description = "Valkey auth token for ${var.environment} environment"
  type        = "SecureString"
  value       = "${var.environment}-${random_uuid.redis_password.result}"
  key_id      = var.kms_key_id

  tags = {
    Name        = "${var.project}-${var.environment}-redis-password"
    Environment = var.environment
  }
}

resource "aws_elasticache_serverless_cache" "main" {
  name                 = "${var.project}-${var.environment}-valkey"
  engine               = "valkey"
  major_engine_version = var.engine_version

  cache_usage_limits {
    data_storage {
      maximum = var.max_data_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.max_ecpu_per_second
    }
  }

  security_group_ids = [var.cache_security_group_id]
  subnet_ids         = var.private_subnet_ids
  user_group_id      = aws_elasticache_user_group.main.id

  tags = {
    Name = "${var.project}-${var.environment}-valkey"
  }

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

resource "aws_elasticache_user" "main" {
  user_id       = "${var.project}-${var.environment}-user"
  user_name     = "default"
  access_string = "on ~* +@all"
  engine        = "VALKEY"
  passwords     = [aws_ssm_parameter.redis_password.value]
}

resource "aws_elasticache_user_group" "main" {
  user_group_id = "${var.project}-${var.environment}-user-group"
  engine        = "VALKEY"
  user_ids      = [aws_elasticache_user.main.user_id]
}
