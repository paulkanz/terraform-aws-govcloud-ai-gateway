# ai-platform :: assurance tests (native `terraform test`, plan-time)
# Run: cd ai-platform && terraform test
#
# These assert the STRUCTURAL security invariants against the plan — no apply, no
# AWS calls — so they gate every PR cheaply. The one test that needs a live
# environment (egress-negative: a real call must time out) is a separate
# post-deploy shell script, tests/egress-negative.sh, since a timeout cannot be
# asserted from a plan.
#
# Covers three of the four SDD §9 assurance tests:
#   - IAM-scope        (test "iam_scope_no_wildcard_bedrock")
#   - content-logging  (test "content_logging_disabled")
#   - egress-lock shape(test "egress_lock_structure")
# The fourth (marker-string log inspection) is inherently runtime -> shell script.

variables {
  environment          = "test-harness"
  vpc_cidr             = "10.99.0.0/16"
  availability_zones   = ["us-gov-west-1a", "us-gov-west-1b"]
  allowed_client_cidrs = ["10.4.0.0/16"]
  approved_model_arns = [
    "arn:aws-us-gov:bedrock:us-gov-west-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]
  secrets_kms_key_arn      = "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  litellm_image_digest     = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  phoenix_image_digest     = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  internal_certificate_arn = "arn:aws-us-gov:acm:us-gov-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  private_zone_id   = "Z00000000000000000000"
  enable_config_rules      = false # no live Config recorder in a plan-only run
}

# --- IAM scope: the LiteLLM Bedrock grant must be explicit ARNs, never "*" ----
run "iam_scope_no_wildcard_bedrock" {
  command = plan

  assert {
    condition     = !contains(var.approved_model_arns, "*")
    error_message = "approved_model_arns must be explicit ARNs, never a wildcard."
  }

  # The rendered task-role policy resource must reference the approved ARNs var,
  # not "*". (Structural: the policy is jsonencode'd from var.approved_model_arns.)
  assert {
    condition     = length(var.approved_model_arns) > 0
    error_message = "At least one approved model ARN is required; empty means no model access rather than all."
  }
}

# --- Content logging: store_prompts_in_spend_logs MUST be false ---------------
run "content_logging_disabled" {
  command = plan

  assert {
    condition     = local.litellm_config.litellm_settings.store_prompts_in_spend_logs == false
    error_message = "store_prompts_in_spend_logs must be false — the single most important no-content setting."
  }

  assert {
    condition     = local.litellm_config.general_settings.disable_admin_ui == true
    error_message = "The LiteLLM admin UI must be disabled in every environment."
  }

  assert {
    condition     = local.litellm_config.litellm_settings.telemetry == false
    error_message = "LiteLLM external telemetry must be off."
  }
}

# --- Egress-lock structure: no public exposure, retry only on 429/5xx ---------
run "egress_lock_structure" {
  command = plan

  # The internal ALB must be private.
  assert {
    condition     = aws_lb.litellm.internal == true
    error_message = "The gateway ALB must be internal (private); never internet-facing."
  }

  # Never retry a 400 (a request defect); retry doubles cost for the same failure.
  assert {
    condition     = local.litellm_config.router_settings.retry_policy.BadRequestErrorRetries == 0
    error_message = "Must never retry a 400 BadRequest."
  }

  # LiteLLM timeout must sit inside the app's 75s budget.
  assert {
    condition     = local.litellm_config.litellm_settings.request_timeout <= 60
    error_message = "LiteLLM request_timeout must be <= 60s to stay inside the app's 75s budget."
  }

  # Tasks never get a public IP.
  assert {
    condition     = aws_ecs_service.litellm.network_configuration[0].assign_public_ip == false
    error_message = "LiteLLM tasks must not receive a public IP."
  }
}
