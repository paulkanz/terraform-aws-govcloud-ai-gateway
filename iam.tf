# ai-platform :: IAM for the LiteLLM ECS task (rule 2 of the egress lock)
#
# The LiteLLM task role is the ONLY principal that may call Bedrock, and only the
# approved model ARNs, with NO wildcards. Adding a model is an IaC change under
# review (edit var.approved_model_arns). Combined with the endpoint policy in
# network.tf and the sg-litellm-only endpoint SG, this is the egress lock.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# --- Task role: the identity that invokes Bedrock via SigV4 ------------------
resource "aws_iam_role" "litellm_task" {
  name        = "${local.name}-litellm-task"
  description = "LiteLLM proxy task role — the sole principal permitted to invoke Bedrock"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Name = "${local.name}-litellm-task" }
}

resource "aws_iam_policy" "litellm_bedrock" {
  name        = "${local.name}-litellm-bedrock"
  description = "LiteLLM Bedrock InvokeModel on approved model ARNs only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeApprovedModelsOnly"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = var.approved_model_arns # explicit ARNs, never "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "litellm_bedrock" {
  role       = aws_iam_role.litellm_task.name
  policy_arn = aws_iam_policy.litellm_bedrock.arn
}

# Transcribe, when the app selects that engine. Scoped to jobs; KMS handled via
# the S3 prefixes the app's own (separate) role writes. Present here only if the
# LiteLLM/platform layer needs it; the app's transcription role is app-owned.
resource "aws_iam_policy" "litellm_transcribe" {
  count       = var.enable_transcribe ? 1 : 0
  name        = "${local.name}-litellm-transcribe"
  description = "LiteLLM Amazon Transcribe jobs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
      Resource = "*" # Transcribe job ARNs are not prefixable; constrain via S3/KMS on the data
    }]
  })
}

resource "aws_iam_role_policy_attachment" "litellm_transcribe" {
  count      = var.enable_transcribe ? 1 : 0
  role       = aws_iam_role.litellm_task.name
  policy_arn = aws_iam_policy.litellm_transcribe[0].arn
}

# SSM read for the gateway config/virtual keys mounted at task start.
resource "aws_iam_policy" "litellm_ssm" {
  name        = "${local.name}-litellm-ssm"
  description = "LiteLLM task SSM read for gateway config/keys + KMS decrypt"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_config_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.secrets_kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "litellm_ssm" {
  role       = aws_iam_role.litellm_task.name
  policy_arn = aws_iam_policy.litellm_ssm.arn
}

# --- Execution role (image pull, secrets injection, logs) --------------------
resource "aws_iam_role" "litellm_execution" {
  name        = "${local.name}-litellm-execution"
  description = "LiteLLM ECS execution role — ECR pull + secret injection + logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Name = "${local.name}-litellm-execution" }
}

resource "aws_iam_role_policy_attachment" "litellm_execution" {
  role       = aws_iam_role.litellm_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy does NOT grant SSM read for secret injection. Grant the
# execution role read on this stack's secrets (/ecs/ai-platform/*) plus the cache
# module's Valkey AUTH token (which the shared module writes under
# /ecs/enterprise-app/<env>/REDIS_PASSWORD), and KMS decrypt on the relevant keys.
resource "aws_iam_policy" "litellm_execution_secrets" {
  name        = "${local.name}-litellm-execution-secrets"
  description = "ECS execution-role SSM read for secret injection + KMS decrypt"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_config_prefix}/${var.environment}/*",
          module.litellm_cache.redis_password_ssm_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.secrets_kms_key_arn, aws_kms_key.platform.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "litellm_execution_secrets" {
  role       = aws_iam_role.litellm_execution.name
  policy_arn = aws_iam_policy.litellm_execution_secrets.arn
}

# NOTE (rule 3 of the egress lock — SCP / permission boundary):
# An organization SCP (or a permission boundary applied to every other role in
# this account) must DENY bedrock:* to every principal EXCEPT
# aws_iam_role.litellm_task. That is an org-management-account change, not an
# account-local resource, so it is NOT created here — it is a documented
# dependency (see the SDD §4). Track as its own card. Without it, the endpoint
# policy + SG are still primary, but an app/CI/developer role with an incidental
# bedrock:InvokeModel grant elsewhere would not be centrally denied.
