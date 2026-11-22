# ai-platform :: LiteLLM policy config + SSM parameters
# This is where the actual policy lives: the model allow-list, alias->model map,
# the single most important setting (store_prompts_in_spend_logs:false), budgets,
# rate limits and nested timeouts. Version-controlled here, mounted from SSM at
# task start — a reviewed change, never a runtime admin action.

# --- config.yaml (rendered from the alias map, published to SSM) -------------
# Rendered rather than a static file so the alias->model mapping stays a single
# source of truth (var.model_aliases) and unknown models are rejected by the
# allow-list (only these aliases resolve).
locals {
  litellm_config = {
    model_list = [
      for alias, m in var.model_aliases : {
        model_name = alias
        litellm_params = {
          model           = "bedrock/${m.model_id}"
          aws_region_name = var.aws_region
          # No credentials block: SigV4 under the ECS task role. No key exists.
        }
      }
    ]

    litellm_settings = {
      # THE single most important setting in the whole design: request/response
      # bodies are never persisted. Verified by the content-logging test.
      store_prompts_in_spend_logs = false
      drop_params                 = true
      request_timeout             = 60 # inside the app's 75s budget
      num_retries                 = 2  # 429/5xx only (see router_settings)
      telemetry                   = false
    }

    router_settings = {
      routing_strategy = "simple-shuffle"
      allowed_fails    = 3
      cooldown_time    = 30
      retry_after      = 5
      # Retry only on throttle/5xx; never retry a 400 (a request defect).
      retry_policy = {
        RateLimitErrorRetries      = 2
        InternalServerErrorRetries = 2
        BadRequestErrorRetries     = 0
        AuthenticationErrorRetries = 0
        TimeoutErrorRetries        = 1
      }
    }

    general_settings = {
      # Admin UI / key-generation surface off in every environment.
      disable_admin_ui                 = true
      allow_requests_on_db_unavailable = false
    }
  }
}

resource "aws_ssm_parameter" "litellm_config" {
  name   = "${var.ssm_config_prefix}/${var.environment}/litellm/config_yaml"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = yamlencode(local.litellm_config)
  tier   = "Advanced" # config can exceed the 4KB Standard limit

  tags = { Name = "${local.name}-litellm-config" }
}

# --- Datastore connection secrets (assembled from the created resources) ------
# DATABASE_URL / REDIS_URL are assembled here from the RDS master secret and the
# cache endpoint. The RDS master password lives in the managed secret; we do NOT
# copy it into a plaintext param — instead the URL param references are built at
# apply from the managed secret's generated password via a data source.
data "aws_secretsmanager_secret_version" "litellm_db" {
  secret_id  = module.litellm_db.master_user_secret_arn
  depends_on = [module.litellm_db]
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.litellm_db.secret_string)
  db_url   = "postgresql://${local.db_creds.username}:${local.db_creds.password}@${module.litellm_db.cluster_endpoint}:5432/litellm"
  # host:port only — the AUTH token is injected separately as REDIS_PASSWORD from
  # the cache module's SSM SecureString (never embedded in this URL / a local).
  redis_url = "rediss://${module.litellm_cache.cache_endpoint}:${module.litellm_cache.cache_port}"
}

resource "aws_ssm_parameter" "database_url" {
  name   = "${var.ssm_config_prefix}/${var.environment}/litellm/DATABASE_URL"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = local.db_url
  tags   = { Name = "${local.name}-litellm-db-url" }
}

resource "aws_ssm_parameter" "redis_url" {
  name   = "${var.ssm_config_prefix}/${var.environment}/litellm/REDIS_URL"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = local.redis_url
  tags   = { Name = "${local.name}-litellm-redis-url" }
}

# --- Master + salt keys (generated, stored, never emitted) -------------------
resource "random_password" "litellm_master" {
  length  = 40
  special = false
}

resource "random_password" "litellm_salt" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "master_key" {
  name   = "${var.ssm_config_prefix}/${var.environment}/litellm/MASTER_KEY"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = "sk-${random_password.litellm_master.result}"
  tags   = { Name = "${local.name}-litellm-master-key" }
}

resource "aws_ssm_parameter" "salt_key" {
  name   = "${var.ssm_config_prefix}/${var.environment}/litellm/SALT_KEY"
  type   = "SecureString"
  key_id = local.secrets_kms_key_arn
  value  = random_password.litellm_salt.result
  tags   = { Name = "${local.name}-litellm-salt-key" }
}

# --- Per-feature virtual keys ------------------------------------------------
# One virtual key per (service, feature) — a small stable set. The TENANT rides
# as the LiteLLM team in request metadata (server-derived), never a separate key.
# These are seeded here; LiteLLM associates them with budgets/teams at runtime
# via its admin API (a bootstrap job), or they are pre-generated placeholders the
# app reads. Value is a generated key the app injects as the Bearer token.
resource "random_password" "feature_key" {
  for_each = toset(var.feature_keys)
  length   = 40
  special  = false
}

resource "aws_ssm_parameter" "feature_key" {
  for_each = toset(var.feature_keys)
  name     = "${var.ssm_config_prefix}/${var.environment}/litellm/key/${each.value}"
  type     = "SecureString"
  key_id   = local.secrets_kms_key_arn
  value    = "sk-${var.environment}-${each.value}-${random_password.feature_key[each.value].result}"
  tags     = { Name = "${local.name}-litellm-key-${each.value}" }
}
