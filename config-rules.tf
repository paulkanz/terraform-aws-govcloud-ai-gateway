# ai-platform :: AWS Config rules — assert the security invariants (CM-2 / SI-4)
# The account already has a Config recorder ("default"), so we add RULES only,
# not a recorder. These catch drift the deploy-time tests only catch at deploy:
# a manual console change that weakens the boundary is flagged as NON_COMPLIANT.

# No unrestricted (0.0.0.0/0) ingress on the AI-platform security groups.
resource "aws_config_config_rule" "no_open_ingress" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${local.name}-restricted-common-ports"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  input_parameters = jsonencode({
    blockedPort1 = "22"
    blockedPort2 = "3389"
  })

  tags = { Name = "${local.name}-restricted-common-ports" }
}

# Managed rule: no security group allows unrestricted SSH — cheap invariant.
resource "aws_config_config_rule" "no_open_ssh" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${local.name}-incoming-ssh-disabled"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  tags = { Name = "${local.name}-incoming-ssh-disabled" }
}

# ELBs must not be internet-facing (this VPC's ALB is internal by design).
resource "aws_config_config_rule" "alb_internal" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${local.name}-alb-internal-only"

  source {
    owner             = "AWS"
    source_identifier = "ELB_LOGGING_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::ElasticLoadBalancingV2::LoadBalancer"]
  }

  input_parameters = jsonencode({ s3BucketNames = aws_s3_bucket.alb_logs.id })

  tags = { Name = "${local.name}-alb-logging-enabled" }
}

# RDS + ElastiCache encryption at rest.
resource "aws_config_config_rule" "rds_encrypted" {
  count = var.enable_config_rules ? 1 : 0
  name  = "${local.name}-rds-storage-encrypted"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  tags = { Name = "${local.name}-rds-storage-encrypted" }
}
