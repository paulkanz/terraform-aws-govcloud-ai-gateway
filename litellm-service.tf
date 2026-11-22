# ai-platform :: LiteLLM ECS service + internal ALB
# The gateway itself: an internal (private) ALB fronting a Fargate service that
# runs the litellm-proxy image (digest-pinned). Reached only from the peered
# client VPCs via the private Route53 record; egress to Bedrock only.

# --- ECS cluster -------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = local.name }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# --- Internal ALB ------------------------------------------------------------
resource "aws_lb" "litellm" {
  name               = "${local.name}-litellm"
  internal           = true # private — reached only from peered client VPCs
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = var.environment
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = { Name = "${local.name}-litellm-alb" }
}

resource "aws_lb_target_group" "litellm" {
  name        = "${local.name}-litellm"
  port        = var.litellm_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health/liveliness"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = { Name = "${local.name}-litellm-tg" }
}

# HTTPS listener. Certificate is for the internal name; ACM cert ARN is a
# CONFIRM item (private CA or an ACM cert for the internal zone).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.litellm.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = var.internal_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }
}

# --- Task definition ---------------------------------------------------------
# Image is digest-pinned from our own ECR mirror; never a public pull at task
# start. When the digest is set (post-ECR-mirror) it is used (CM-8/SR-4 — a
# digest can't drift); otherwise it falls back to the pinned TAG so the config
# is plan-valid before the first mirror. An apply for real should carry a digest.
locals {
  litellm_image = var.litellm_image_digest != "" ? "${aws_ecr_repository.litellm.repository_url}@${var.litellm_image_digest}" : "${aws_ecr_repository.litellm.repository_url}:${var.litellm_image_tag}"
  phoenix_image = var.phoenix_image_digest != "" ? "${aws_ecr_repository.phoenix.repository_url}@${var.phoenix_image_digest}" : "${aws_ecr_repository.phoenix.repository_url}:${var.phoenix_image_tag}"
}

resource "aws_ecs_task_definition" "litellm" {
  family                   = "${local.name}-litellm"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.litellm_cpu
  memory                   = var.litellm_memory
  execution_role_arn       = aws_iam_role.litellm_execution.arn
  task_role_arn            = aws_iam_role.litellm_task.arn

  container_definitions = jsonencode([{
    name      = "litellm"
    image     = local.litellm_image
    essential = true

    portMappings = [{
      containerPort = var.litellm_port
      protocol      = "tcp"
    }]

    # Non-secret runtime config. The model list, aliases, allow-list and
    # store_prompts_in_spend_logs:false live in the mounted config.yaml.
    environment = [
      { name = "LITELLM_MODE", value = "PRODUCTION" },
      { name = "PORT", value = tostring(var.litellm_port) },
      { name = "STORE_MODEL_IN_DB", value = "false" }, # config is IaC, not runtime-admin
      { name = "DISABLE_ADMIN_UI", value = "true" },   # admin UI off in all envs
      { name = "AWS_REGION", value = var.aws_region },
    ]

    # Secrets from SSM SecureString (DB URL, cache URL, master/salt keys).
    secrets = [
      { name = "DATABASE_URL", valueFrom = "${local.ssm_base}/litellm/DATABASE_URL" },
      { name = "REDIS_URL", valueFrom = "${local.ssm_base}/litellm/REDIS_URL" },
      { name = "REDIS_PASSWORD", valueFrom = module.litellm_cache.redis_password_ssm_arn },
      { name = "LITELLM_MASTER_KEY", valueFrom = "${local.ssm_base}/litellm/MASTER_KEY" },
      { name = "LITELLM_SALT_KEY", valueFrom = "${local.ssm_base}/litellm/SALT_KEY" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.litellm.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "litellm"
      }
    }
  }])

  tags = { Name = "${local.name}-litellm" }
}

resource "aws_ecs_service" "litellm" {
  name            = "litellm"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = var.litellm_desired_count # >= 2 across 2 AZs
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.litellm.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "litellm"
    container_port   = var.litellm_port
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  health_check_grace_period_seconds  = 60

  depends_on = [aws_lb_listener.https]

  tags = { Name = "${local.name}-litellm" }
}
