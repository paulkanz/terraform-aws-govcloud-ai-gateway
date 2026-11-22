# ai-platform :: Phoenix observability (self-hosted, metadata-only)
# Phoenix runs as infrastructure so prompt evaluation is available when someone
# owns it; WHAT the app sends is a separate (app) decision and is metadata-only.
# Phoenix is NEVER a hard dependency — telemetry export is fire-and-forget with a
# circuit breaker on the app side; nothing here may fail a case note.
#
# Content suppression is enforced app-side (instrumentor suppresses span
# input/output). The marker-string test asserts no content reaches these spans.

# --- SGs: Phoenix task + its own DB ------------------------------------------
resource "aws_security_group" "phoenix" {
  name        = "${local.name}-phoenix"
  description = "Phoenix tasks"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-phoenix" }
}

resource "aws_security_group" "phoenix_db" {
  name        = "${local.name}-phoenix-db"
  description = "Phoenix RDS; admits 5432 from the phoenix tasks only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-phoenix-db" }
}

# Phoenix reached via the same internal ALB (separate listener rule / host) from
# the client VPCs; ingress from the ALB SG.
resource "aws_vpc_security_group_ingress_rule" "phoenix_from_alb" {
  security_group_id            = aws_security_group.phoenix.id
  description                  = "From the internal ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.phoenix_port
  to_port                      = var.phoenix_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_phoenix" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the Phoenix tasks"
  referenced_security_group_id = aws_security_group.phoenix.id
  from_port                    = var.phoenix_port
  to_port                      = var.phoenix_port
  ip_protocol                  = "tcp"
}

# Phoenix -> its DB, and -> the interface endpoints (SSM, logs, ecr) at 443.
resource "aws_vpc_security_group_ingress_rule" "phoenix_db_from_phoenix" {
  security_group_id            = aws_security_group.phoenix_db.id
  description                  = "PostgreSQL from the Phoenix tasks"
  referenced_security_group_id = aws_security_group.phoenix.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "phoenix_to_db" {
  security_group_id            = aws_security_group.phoenix.id
  description                  = "PostgreSQL to the Phoenix RDS"
  referenced_security_group_id = aws_security_group.phoenix_db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "phoenix_to_vpce" {
  security_group_id            = aws_security_group.phoenix.id
  description                  = "HTTPS to AWS interface endpoints"
  referenced_security_group_id = aws_security_group.vpce.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# vpce admits 443 from phoenix too (ingress rule to the shared endpoint SG).
resource "aws_vpc_security_group_ingress_rule" "vpce_from_phoenix" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS from Phoenix"
  referenced_security_group_id = aws_security_group.phoenix.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# --- Phoenix PostgreSQL (not SQLite — encrypted, backed up) via modules/database
module "phoenix_db" {
  source = "./modules/database"

  project                    = "${var.project}-phoenix" # distinct identifiers from the litellm cluster
  environment                = var.environment
  database_name              = "phoenix"
  database_subnet_ids        = aws_subnet.private[*].id
  database_security_group_id = aws_security_group.phoenix_db.id
  kms_key_arn                = aws_kms_key.platform.arn
  secrets_kms_key_arn        = local.secrets_kms_key_arn
  min_capacity               = var.db_min_capacity
  max_capacity               = var.db_max_capacity
  instance_count             = 1
}

# --- ECR + log group ---------------------------------------------------------
resource "aws_ecr_repository" "phoenix" {
  name                 = "${local.name}/phoenix"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.platform.arn
  }

  tags = { Name = "${local.name}-phoenix-ecr" }
}

resource "aws_cloudwatch_log_group" "phoenix" {
  name              = "/ecs/${local.name}/phoenix"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
  tags              = { Name = "${local.name}-phoenix-logs" }
}

# --- Phoenix DB URL secret ---------------------------------------------------
data "aws_secretsmanager_secret_version" "phoenix_db" {
  secret_id  = module.phoenix_db.master_user_secret_arn
  depends_on = [module.phoenix_db]
}

locals {
  phoenix_db_creds = jsondecode(data.aws_secretsmanager_secret_version.phoenix_db.secret_string)
  phoenix_db_url   = "postgresql://${local.phoenix_db_creds.username}:${local.phoenix_db_creds.password}@${module.phoenix_db.cluster_endpoint}:5432/phoenix"
}

resource "aws_ssm_parameter" "phoenix_db_url" {
  name   = "${var.ssm_config_prefix}/${var.environment}/phoenix/DATABASE_URL"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = local.phoenix_db_url
  tags   = { Name = "${local.name}-phoenix-db-url" }
}

# --- Phoenix ECS service (on the shared cluster) -----------------------------
resource "aws_lb_target_group" "phoenix" {
  name        = "${local.name}-phoenix"
  port        = var.phoenix_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30
  tags                 = { Name = "${local.name}-phoenix-tg" }
}

# Host-based rule on the shared internal ALB HTTPS listener: phoenix.<zone> ->
# Phoenix, everything else -> LiteLLM (the listener default).
resource "aws_lb_listener_rule" "phoenix" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.phoenix.arn
  }

  condition {
    host_header {
      values = ["${var.phoenix_host_label}.ai-gateway.internal"]
    }
  }
}

resource "aws_route53_record" "phoenix" {
  zone_id = var.private_zone_id
  name    = "${var.phoenix_host_label}.ai-gateway.internal" # e.g. phoenix-aiplatform.ai-gateway.internal
  type    = "A"

  alias {
    name                   = aws_lb.litellm.dns_name # same internal ALB
    zone_id                = aws_lb.litellm.zone_id
    evaluate_target_health = true
  }
}

resource "aws_ecs_task_definition" "phoenix" {
  family                   = "${local.name}-phoenix"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.phoenix_cpu
  memory                   = var.phoenix_memory
  execution_role_arn       = aws_iam_role.litellm_execution.arn # reuse exec role (ECR pull + secrets + logs)
  task_role_arn            = aws_iam_role.phoenix_task.arn

  container_definitions = jsonencode([{
    name      = "phoenix"
    image     = local.phoenix_image
    essential = true

    portMappings = [{ containerPort = var.phoenix_port, protocol = "tcp" }]

    environment = [
      { name = "PHOENIX_PORT", value = tostring(var.phoenix_port) },
      { name = "PHOENIX_WORKING_DIR", value = "/mnt/data" },
    ]

    secrets = [
      { name = "PHOENIX_SQL_DATABASE_URL", valueFrom = "${local.ssm_base}/phoenix/DATABASE_URL" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.phoenix.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "phoenix"
      }
    }
  }])

  tags = { Name = "${local.name}-phoenix" }
}

resource "aws_ecs_service" "phoenix" {
  name            = "phoenix"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.phoenix.arn
  desired_count   = 1 # observability, not a hard dependency; single task is fine
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.phoenix.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.phoenix.arn
    container_name   = "phoenix"
    container_port   = var.phoenix_port
  }

  depends_on = [aws_lb_listener.https]
  tags       = { Name = "${local.name}-phoenix" }
}

# --- Phoenix task role (minimal — logs + SSM read for its DB URL) ------------
resource "aws_iam_role" "phoenix_task" {
  name = "${local.name}-phoenix-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Name = "${local.name}-phoenix-task" }
}

resource "aws_iam_policy" "phoenix_ssm" {
  name        = "${local.name}-phoenix-ssm"
  description = "Phoenix task SSM read for its DB URL + KMS decrypt"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_config_prefix}/${var.environment}/phoenix/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.secrets_kms_key_arn, aws_kms_key.platform.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "phoenix_ssm" {
  role       = aws_iam_role.phoenix_task.name
  policy_arn = aws_iam_policy.phoenix_ssm.arn
}

# NOTE: OIDC auth in front of Phoenix (against the same IdP) is applied at the
# Phoenix app layer / an ALB OIDC authenticate action — CONFIRM the IdP client
# config; tracked with the LiteLLM cert/OIDC card. Phoenix must never be public.
