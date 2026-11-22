# ai-platform :: outputs (the platform side of the interface contract)

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "litellm_security_group_id" {
  description = "sg-litellm — the sole principal the Bedrock endpoint admits"
  value       = aws_security_group.litellm.id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "vpce_security_group_id" {
  value = aws_security_group.vpce.id
}

output "litellm_task_role_arn" {
  description = "The only IAM principal permitted to invoke Bedrock"
  value       = aws_iam_role.litellm_task.arn
}

output "litellm_execution_role_arn" {
  value = aws_iam_role.litellm_execution.arn
}

output "bedrock_endpoint_id" {
  value = aws_vpc_endpoint.bedrock_runtime.id
}

output "client_peering_ids" {
  description = "Peering connection ids per client VPC (for the client-side return routes)"
  value       = { for k, v in aws_vpc_peering_connection.client : k => v.id }
}

# --- LiteLLM contract outputs (what the app/ai-gateway library consumes) ------
output "litellm_internal_url" {
  description = "The gateway URL the app points ai-gateway at (private ai-gateway.internal DNS)."
  value       = "https://${var.litellm_host_label}.ai-gateway.internal"
}

output "litellm_alb_dns_name" {
  value = aws_lb.litellm.dns_name
}

output "litellm_ecr_repository_url" {
  value = aws_ecr_repository.litellm.repository_url
}

output "litellm_log_group" {
  value = aws_cloudwatch_log_group.litellm.name
}

output "platform_kms_key_arn" {
  value = aws_kms_key.platform.arn
}

output "internal_zone_id" {
  value = var.private_zone_id
}

output "phoenix_internal_url" {
  value = "https://${var.phoenix_host_label}.ai-gateway.internal"
}

output "phoenix_ecr_repository_url" {
  value = aws_ecr_repository.phoenix.repository_url
}

output "alerts_sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "deploy_role_arn" {
  description = "GitHub Actions OIDC role to set as AWS_OIDC_ROLE_ARN on the ai-platform-<env> GitHub Environment"
  value       = aws_iam_role.deploy.arn
}

output "flow_log_group" {
  value = aws_cloudwatch_log_group.flow.name
}

output "alb_logs_bucket" {
  value = aws_s3_bucket.alb_logs.id
}
