output "cluster_id" {
  value = aws_rds_cluster.main.id
}

output "cluster_endpoint" {
  value = aws_rds_cluster.main.endpoint
}

output "reader_endpoint" {
  value = aws_rds_cluster.main.reader_endpoint
}

output "cluster_arn" {
  value = aws_rds_cluster.main.arn
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master user secret (for callers assembling a connection URL)."
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}
