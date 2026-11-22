# ai-platform :: variables

variable "project" {
  type    = string
  default = "ai-platform"
}

variable "environment" {
  description = "poc | test | staging | prod"
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-gov-west-1"
}

variable "vpc_cidr" {
  description = "ai-platform VPC CIDR. poc 10.50, test 10.51, staging 10.52, prod 10.53."
  type        = string
}

variable "availability_zones" {
  type = list(string)
}

# --- Client reachability (the Swarm->Fargate migration seam) -----------------
# allowed_client_cidrs: CIDRs admitted on the internal ALB (443). Cross-VPC and
# peered, so CIDR-based rather than SG-based. Holds the Swarm CIDR now; the
# Enterprise-App-Fargate CIDR is APPENDED at migration — additive, never a rebuild.
variable "allowed_client_cidrs" {
  type = list(string)
}

# client_vpc_peers: one entry per client VPC that must reach the gateway. The
# requester side of the peering + this side's route are created here; the client
# side's return route is owned by whoever owns that VPC's route tables (configured via the respective client VPC route tables).
variable "client_vpc_peers" {
  type = map(object({
    vpc_id       = string
    cidr         = string
    same_account = bool
  }))
  default = {}
}

# --- Egress lock: the approved Bedrock model ARNs (NO wildcards) -------------
variable "approved_model_arns" {
  description = "Exact Bedrock foundation-model / inference-profile ARNs LiteLLM may invoke. Adding one is a reviewed IaC change."
  type        = list(string)
}

# bedrock-runtime vs bedrock-runtime-fips — CONFIRM the FIPS obligation at
# Moderate (SC-13). Default to the FIPS endpoint.
variable "bedrock_endpoint_service" {
  type    = string
  default = "bedrock-runtime-fips"
}

variable "enable_transcribe" {
  type    = bool
  default = false # option, not a gate; Claude-via-Bedrock covers transcription
}

variable "transcribe_endpoint_service" {
  type    = string
  default = "transcribe-fips"
}

variable "support_interface_endpoints" {
  description = "AWS interface endpoints the no-NAT private subnets need."
  type        = list(string)
  default     = ["ssm", "secretsmanager", "logs", "monitoring", "ecr.api", "ecr.dkr", "sts"]
}

variable "litellm_port" {
  type    = number
  default = 4000
}

variable "ssm_config_prefix" {
  description = "SSM path prefix for the gateway config + virtual keys."
  type        = string
  default     = "/ecs/ai-platform" # e.g. /ecs/ai-platform/<env>/litellm/*
}

variable "secrets_kms_key_arn" {
  description = "KMS key for the gateway's SSM SecureStrings. Empty (default) uses the stack's own platform CMK (aws_kms_key.platform) — see local.secrets_kms_key_arn. Set only to reuse an existing external secrets CMK."
  type        = string
  default     = ""
}

# --- LiteLLM service ---------------------------------------------------------
variable "litellm_image_digest" {
  description = "sha256 digest of the litellm-proxy image in our ECR (preferred — a digest can't drift). Empty falls back to litellm_image_tag (plan-valid pre-mirror); set the digest for a real apply."
  type        = string
  default     = ""
}

variable "litellm_image_tag" {
  description = "Tag fallback used only when litellm_image_digest is empty (pre-ECR-mirror). Pin the intended upstream release."
  type        = string
  default     = "main-stable"
}

variable "litellm_cpu" {
  type    = string
  default = "1024"
}

variable "litellm_memory" {
  type    = string
  default = "2048"
}

variable "litellm_desired_count" {
  type    = number
  default = 2 # >= 2 across 2 AZs
}

variable "internal_certificate_arn" {
  description = "ACM cert for the internal ALB (private CA or ACM for the internal zone). CONFIRM."
  type        = string
}

variable "private_zone_id" {
  description = "The existing private ai-gateway.internal Route53 hosted zone id (ZXXXXXXXXXXXXXXXXXXXX) — gateway records land here so the imported *.ai-gateway.internal cert validates with no client trust distribution."
  type        = string
}

variable "litellm_host_label" {
  description = "Single label under ai-gateway.internal for the gateway (matches *.ai-gateway.internal), e.g. litellm-aiplatform -> litellm-aiplatform.ai-gateway.internal."
  type        = string
  default     = "litellm-aiplatform"
}

variable "phoenix_host_label" {
  description = "Single label under ai-gateway.internal for Phoenix, e.g. phoenix-aiplatform."
  type        = string
  default     = "phoenix-aiplatform"
}

# --- Datastores --------------------------------------------------------------
variable "log_retention_days" {
  type    = number
  default = 30
}

variable "db_min_capacity" {
  type    = number
  default = 0.5
}

variable "db_max_capacity" {
  type    = number
  default = 4
}

variable "db_instance_count" {
  type    = number
  default = 1 # 2 for prod (Multi-AZ)
}

variable "cache_max_gb" {
  type    = number
  default = 5
}

variable "cache_max_ecpu" {
  type    = number
  default = 5000
}

# --- LiteLLM policy: alias -> model map + virtual keys -----------------------
# The application only ever names an alias; this maps aliases to the real,
# enabled Bedrock model ids. Only these aliases resolve (allow-list). The
# model_id must correspond to an ARN in var.approved_model_arns (the egress lock).
# Defaults reflect the VERIFIED gov-west-1 catalog: Sonnet 4.5 + Fable 5.1
# (NO Haiku enabled — differs from the design; revisit with the eval corpus).
variable "model_aliases" {
  type = map(object({
    model_id = string
  }))
  default = {
    "case-note-summary"     = { model_id = "anthropic.claude-sonnet-4-5-20250929-v1:0" }
    "case-note-transcribe"  = { model_id = "anthropic.claude-sonnet-4-5-20250929-v1:0" }
    "structured-extraction" = { model_id = "anthropic.claude-sonnet-4-5-20250929-v1:0" }
    "ops-analysis"          = { model_id = "anthropic.claude-fable-5-1" }
  }
}

# One virtual key per (service, feature). Tenant rides as the LiteLLM team in
# request metadata, not a per-tenant key.
variable "feature_keys" {
  type    = list(string)
  default = ["app-summarization", "app-transcribe", "app-extraction", "app-ops"]
}

# --- Phoenix -----------------------------------------------------------------
variable "phoenix_image_digest" {
  description = "sha256 digest of the Phoenix image in our ECR (preferred). Empty falls back to phoenix_image_tag (plan-valid pre-mirror)."
  type        = string
  default     = ""
}

variable "phoenix_image_tag" {
  description = "Tag fallback used only when phoenix_image_digest is empty. Pin the intended Phoenix release."
  type        = string
  default     = "version-11.28.0"
}

variable "phoenix_port" {
  type    = number
  default = 6006
}

variable "phoenix_cpu" {
  type    = string
  default = "512"
}

variable "phoenix_memory" {
  type    = string
  default = "1024"
}

# --- Observability -----------------------------------------------------------
variable "alert_email_subscribers" {
  type    = list(string)
  default = []
}

variable "runbook_base_url" {
  type    = string
  default = "https://https://github.com/paulkanz/terraform-aws-govcloud-ai-gateway/blob/main/docs/RUNBOOKS.md"
}

variable "alarm_gateway_5xx_threshold" {
  type    = number
  default = 10
}

variable "alarm_gateway_latency_p95_seconds" {
  type    = number
  default = 55 # approaching the 60s gateway budget
}

variable "alarm_cache_ecpu_threshold" {
  description = "Sustained ECPU (3x5min) that pages. Tune to the real rate-limit-counter profile, not a generic default (tooling BullMQ lesson)."
  type        = number
  default     = 4000
}

# --- AWS Config rules --------------------------------------------------------
variable "enable_config_rules" {
  description = "Add Config rules to the existing account recorder. False in envs without a recorder."
  type        = bool
  default     = true
}

# --- OIDC deploy role --------------------------------------------------------
variable "github_repo" {
  description = "owner/repo the deploy workflow runs from, e.g. paulkanz/terraform-aws-govcloud-ai-gateway"
  type        = string
  default     = "paulkanz/terraform-aws-govcloud-ai-gateway"
}

variable "create_oidc_provider" {
  description = "Bootstrap the GitHub OIDC provider if it does not already exist in the account (it usually does — central-ci-cd created it)."
  type        = bool
  default     = false
}

variable "github_oidc_thumbprints" {
  type    = list(string)
  default = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
