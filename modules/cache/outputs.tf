output "cache_name" {
  value = aws_elasticache_serverless_cache.main.name
}

output "cache_endpoint" {
  value = aws_elasticache_serverless_cache.main.endpoint[0].address
}

output "cache_port" {
  value = aws_elasticache_serverless_cache.main.endpoint[0].port
}

output "redis_password_ssm_arn" {
  description = "ARN of the SecureString holding the Valkey AUTH token (for callers to inject as a secret)."
  value       = aws_ssm_parameter.redis_password.arn
}

output "redis_password_ssm_name" {
  description = "Name of the SecureString holding the Valkey AUTH token."
  value       = aws_ssm_parameter.redis_password.name
}
