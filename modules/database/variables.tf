
variable "database_subnet_ids" {
  type = list(string)
}

variable "database_security_group_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "secrets_kms_key_arn" {
  type        = string
  description = "KMS key ARN for RDS managed master user secret encryption"
}

variable "database_name" {
  type = string
}

variable "min_capacity" {
  type = number
}

variable "max_capacity" {
  type = number
}

variable "instance_count" {
  description = "Number of Aurora Serverless v2 instances. 2 = writer + reader (HA, default, preserves enterprise-app behavior). 1 = single writer only, no reader/failover (cheaper, POC/non-critical)."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1 (a cluster needs a writer)."
  }
}

variable "environment" {
  type = string
}

variable "project" {
  type = string
}
