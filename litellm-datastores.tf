# ai-platform :: LiteLLM supporting datastores + platform plumbing
# RDS PostgreSQL (keys/teams/budgets/usage — NO prompt/response content),
# ElastiCache (rate-limit counters), ECR (digest-pinned, immutable), the log
# group, the platform KMS key, and the private hosted zone for internal
# resolution from the peered client VPCs.

# --- Platform KMS key (logs, RDS, ElastiCache, SSM) --------------------------
# Distinct from any per-tenant CMK: this protects PLATFORM data (which never
# holds participant content), not artifacts. The app's per-tenant CMKs are
# app-owned and live elsewhere.
resource "aws_kms_key" "platform" {
  description             = "${local.name} platform key (RDS, cache, logs, SSM)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = { Name = "${local.name}-platform" }
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${local.name}-platform"
  target_key_id = aws_kms_key.platform.key_id
}

# The KMS key for the gateway's SSM SecureStrings: reuse an external secrets CMK
# if one was supplied, otherwise the stack's own platform CMK (no external dep).
locals {
  secrets_kms_key_arn = var.secrets_kms_key_arn != "" ? var.secrets_kms_key_arn : aws_kms_key.platform.arn
}

# --- CloudWatch log group ----------------------------------------------------
resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${local.name}/litellm"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
  tags              = { Name = "${local.name}-litellm-logs" }
}

# --- ECR: mirror the upstream litellm-proxy image, immutable + scan-on-push --
resource "aws_ecr_repository" "litellm" {
  name                 = "${local.name}/litellm-proxy"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.platform.arn
  }

  tags = { Name = "${local.name}-litellm-ecr" }
}

# --- RDS PostgreSQL (Aurora Serverless v2) -----------------------------------
# LiteLLM's control-plane store: virtual keys, teams, budgets, usage rows.
# Configured to hold NO request/response bodies (store_prompts_in_spend_logs
# false in the LiteLLM config); this DB is keys+usage only. Uses the shared
# modules/database (same as enterprise-app/Data-Platform) — it creates the subnet group,
# cluster, instances, enhanced monitoring, and outputs the master-secret ARN.
resource "aws_security_group" "litellm_db" {
  name        = "${local.name}-litellm-db"
  description = "LiteLLM RDS; admits 5432 from the litellm tasks only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-litellm-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_litellm" {
  security_group_id            = aws_security_group.litellm_db.id
  description                  = "PostgreSQL from the LiteLLM tasks"
  referenced_security_group_id = aws_security_group.litellm.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "litellm_to_db" {
  security_group_id            = aws_security_group.litellm.id
  description                  = "PostgreSQL to the LiteLLM RDS"
  referenced_security_group_id = aws_security_group.litellm_db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

module "litellm_db" {
  source = "./modules/database"

  project                    = var.project
  environment                = var.environment
  database_name              = "litellm"
  database_subnet_ids        = aws_subnet.private[*].id
  database_security_group_id = aws_security_group.litellm_db.id
  kms_key_arn                = aws_kms_key.platform.arn
  secrets_kms_key_arn        = local.secrets_kms_key_arn
  min_capacity               = var.db_min_capacity
  max_capacity               = var.db_max_capacity
  instance_count             = var.db_instance_count
}

# --- ElastiCache (rate-limit counters) ---------------------------------------
resource "aws_security_group" "litellm_cache" {
  name        = "${local.name}-litellm-cache"
  description = "LiteLLM ElastiCache; admits 6379 from the litellm tasks only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-litellm-cache" }
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_litellm" {
  security_group_id            = aws_security_group.litellm_cache.id
  description                  = "Valkey/Redis from the LiteLLM tasks"
  referenced_security_group_id = aws_security_group.litellm.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "litellm_to_cache" {
  security_group_id            = aws_security_group.litellm.id
  description                  = "Valkey/Redis to the LiteLLM cache"
  referenced_security_group_id = aws_security_group.litellm_cache.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

module "litellm_cache" {
  source = "./modules/cache"

  project                 = var.project
  environment             = var.environment
  private_subnet_ids      = aws_subnet.private[*].id
  cache_security_group_id = aws_security_group.litellm_cache.id
  max_data_storage_gb     = var.cache_max_gb
  max_ecpu_per_second     = var.cache_max_ecpu
  kms_key_id              = aws_kms_key.platform.arn
  engine_version          = "8"
}

# --- DNS: records in the EXISTING private ai-gateway.internal zone --------------------
# The gateway resolves as a single-label ai-gateway.internal host so the imported
# *.ai-gateway.internal ACM cert validates with NO client trust distribution (a private CA
# would have to be added to every caller — avoided). The private ai-gateway.internal zone
# (ZXXXXXXXXXXXXXXXXXXXX) is already associated with the Swarm client VPC
# (docker-preprod) and the Enterprise-App-Fargate VPCs, so those resolve the gateway
# with no extra work. We associate the ai-platform VPC too. The ALB is internal,
# so even a real ai-gateway.internal record only resolves to a private IP.
resource "aws_route53_zone_association" "ai_platform_to_govcloud-ai" {
  zone_id = var.private_zone_id
  vpc_id  = aws_vpc.this.id
}

resource "aws_route53_record" "litellm" {
  zone_id = var.private_zone_id
  name    = "${var.litellm_host_label}.ai-gateway.internal" # e.g. litellm-aiplatform.ai-gateway.internal
  type    = "A"

  alias {
    name                   = aws_lb.litellm.dns_name
    zone_id                = aws_lb.litellm.zone_id
    evaluate_target_health = true
  }
}
