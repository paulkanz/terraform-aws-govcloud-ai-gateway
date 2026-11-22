# ai-platform :: network + the Bedrock egress lock
# Enterprise-AI-Platform — Shared AI Platform Foundation. See docs/SDD.md.
#
# Dedicated ai-platform VPC (own CIDR, own state) so the single most sensitive
# egress path in the estate — the only network route to Bedrock — is isolated
# from Enterprise App's blast radius and survives Enterprise App's Swarm->Fargate migration
# untouched. Clients reach it over VPC peering (Swarm today, Enterprise-App-Fargate
# later); the migration is then "add a client CIDR + one peering", never a rebuild.

locals {
  name = "${var.project}-${var.environment}" # e.g. ai-platform-poc
  azs  = var.availability_zones

  # SSM SecureString base for the gateway config + virtual keys.
  # e.g. /ecs/ai-platform/poc/litellm/DATABASE_URL
  ssm_base = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_config_prefix}/${var.environment}"
}

# --- VPC ---------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr # poc 10.50.0.0/16
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

# Private subnets only. There is degovcloud-aitely NO public subnet and NO NAT for
# model traffic: the AI subnets have no internet route at all, so a re-added
# direct provider SDK call cannot reach api.anthropic.com from here.
resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index) # /20s
  tags              = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Client VPC peering (Swarm now; Enterprise-App-Fargate added later) ------------
# One peering per client VPC that must reach the gateway. poc: docker-preprod
# (10.4.0.0/16). The requester side lives here; the accepter route on the client
# side (e.g. docker-preprod's route table -> this CIDR) is added in
# terraform-system/preprod-legacy's data-platform_peerings-style map (the retrofit repo
# owns the legacy Swarm route tables), mirroring the Data-Platform bridge pattern.
resource "aws_vpc_peering_connection" "client" {
  for_each    = var.client_vpc_peers
  vpc_id      = aws_vpc.this.id
  peer_vpc_id = each.value.vpc_id
  auto_accept = each.value.same_account # true when both VPCs are in this account
  tags        = { Name = "${local.name}-to-${each.key}" }
}

resource "aws_route" "to_client" {
  for_each                  = var.client_vpc_peers
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.client[each.key].id
}

# --- Security groups ---------------------------------------------------------
# Cross-referencing rules (alb<->litellm<->vpce) are defined as SEPARATE rule
# resources, not inline, to avoid a security-group dependency cycle.
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internal ALB for the AI gateway; admits only peered client CIDRs on 443"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-alb" }
}

# sg-litellm — THE identity the Bedrock endpoint admits. This SG being the sole
# principal allowed to reach the Bedrock endpoint is the load-bearing control.
resource "aws_security_group" "litellm" {
  name        = "${local.name}-litellm"
  description = "LiteLLM proxy tasks; the ONLY thing permitted to reach the Bedrock endpoint"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-litellm" }
}

# SG shared by the interface VPC endpoints.
resource "aws_security_group" "vpce" {
  name        = "${local.name}-vpce"
  description = "Interface VPC endpoints; admits 443 from in-VPC workloads"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-vpce" }
}

# ALB: ingress 443 from peered client CIDRs (Swarm now, Enterprise-App-Fargate later —
# CIDR-based because clients are always cross-VPC/peered). Egress only to litellm.
resource "aws_vpc_security_group_ingress_rule" "alb_from_clients" {
  for_each          = toset(var.allowed_client_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from a peered client VPC"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_litellm" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the LiteLLM tasks"
  referenced_security_group_id = aws_security_group.litellm.id
  from_port                    = var.litellm_port
  to_port                      = var.litellm_port
  ip_protocol                  = "tcp"
}

# litellm: ingress from the ALB; egress 443 to the endpoint SG only (no 0.0.0.0/0
# -> no path to any public model provider).
resource "aws_vpc_security_group_ingress_rule" "litellm_from_alb" {
  security_group_id            = aws_security_group.litellm.id
  description                  = "From the internal ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.litellm_port
  to_port                      = var.litellm_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "litellm_to_vpce" {
  security_group_id            = aws_security_group.litellm.id
  description                  = "HTTPS to AWS interface endpoints (Bedrock, Transcribe, S3, KMS, SSM, logs, ECR)"
  referenced_security_group_id = aws_security_group.vpce.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# vpce: ingress 443 from litellm (extend to phoenix/app tasks later).
resource "aws_vpc_security_group_ingress_rule" "vpce_from_litellm" {
  security_group_id            = aws_security_group.vpce.id
  description                  = "HTTPS from LiteLLM"
  referenced_security_group_id = aws_security_group.litellm.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# --- Interface VPC endpoints (PrivateLink; no NAT, no internet) --------------
# bedrock-runtime is the model egress. Its endpoint POLICY plus its SG admitting
# only sg-litellm is rule (1) of the egress lock — the primary control.
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${var.bedrock_endpoint_service}" # bedrock-runtime or -fips (see var)
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  # Endpoint policy: only InvokeModel on the approved model ARNs, and only when
  # the caller is the LiteLLM task role. Rule (1) of the egress lock.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyLiteLLMOnlyApprovedModels"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.litellm_task.arn }
      Action    = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource  = var.approved_model_arns
    }]
  })

  tags = { Name = "${local.name}-bedrock-runtime" }
}

resource "aws_vpc_endpoint" "transcribe" {
  count               = var.enable_transcribe ? 1 : 0
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${var.transcribe_endpoint_service}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-transcribe" }
}

# Supporting interface endpoints so the private (no-NAT) subnets can still reach
# the AWS control/data planes LiteLLM and the ECS platform need.
resource "aws_vpc_endpoint" "iface" {
  for_each            = toset(var.support_interface_endpoints) # ssm, secretsmanager, logs, ecr.api, ecr.dkr, monitoring, sts
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.value}" }
}

# Gateway endpoints (S3, and DynamoDB if needed) — free, route-table attached.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${local.name}-s3" }
}
