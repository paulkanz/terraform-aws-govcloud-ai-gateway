# ai-platform :: GitHub Actions OIDC deploy role (CM-2 / CM-3 / AC-6)
# Scoped deploy identity for `tofu apply` of THIS (system, environment), mirroring
# the terraform-system/central-ci-cd pattern: no long-lived keys, the trust policy
# binds the GitHub repo + Environment via the OIDC `sub` claim so an ai-platform-poc
# workflow run cannot assume the prod role.
#
# The GitHub OIDC provider is account-wide and already exists (central-ci-cd created
# it). We reference it by ARN rather than re-creating it (a provider is a singleton
# per account). If it is absent in an env, create_oidc_provider=true bootstraps it.

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints
  tags            = { Name = "${local.name}-github-oidc" }
}

locals {
  github_oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "deploy" {
  name        = "${local.name}-deploy"
  description = "GitHub Actions OIDC deploy role for ai-platform ${var.environment} (tofu apply)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.github_oidc_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Bind to the specific repo + GitHub Environment — a poc run cannot
          # assume the prod role, nor another system's role.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:environment:ai-platform-${var.environment}"
        }
      }
    }]
  })

  tags = { Name = "${local.name}-deploy" }
}

# The deploy role's permissions are intentionally NOT a blanket admin. It gets
# what tofu apply of this stack needs. Scoped by the resources this root manages;
# bedrock:* is degovcloud-aitely EXCLUDED (only the litellm_task role reaches Bedrock).
resource "aws_iam_policy" "deploy" {
  name = "${local.name}-deploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PlatformResources"
        Effect = "Allow"
        Action = [
          "ec2:*", "ecs:*", "elasticloadbalancing:*", "rds:*", "elasticache:*",
          "logs:*", "cloudwatch:*", "sns:*", "route53:*", "ecr:*",
          "kms:*", "ssm:*", "config:*", "s3:*", "application-autoscaling:*"
        ]
        Resource = "*" # scoped by the account boundary + the SCP; tighten per-service later
      },
      {
        Sid      = "PassOnlyThisStacksRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*"
      },
      {
        Sid    = "IamForThisStack"
        Effect = "Allow"
        Action = ["iam:*Role*", "iam:*Policy*", "iam:*OpenIDConnect*", "iam:TagRole", "iam:GetRole", "iam:ListRolePolicies"]
        # IAM changes scoped to this stack's own role name prefix.
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*"
      },
      {
        Sid      = "DenyBedrockToDeployRole"
        Effect   = "Deny"
        Action   = "bedrock:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}
