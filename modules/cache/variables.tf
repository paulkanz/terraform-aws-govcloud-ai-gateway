
variable "private_subnet_ids" {
  type = list(string)
}

variable "cache_security_group_id" {
  type = string
}

variable "max_data_storage_gb" {
  type = number
}

variable "max_ecpu_per_second" {
  type = number
}

variable "environment" {
  type = string
}

variable "project" {
  type = string
}

variable "kms_key_id" {
  description = "KMS key ARN for encrypting SSM parameters"
  type        = string
}

variable "engine_version" {
  description = "Valkey major engine version"
  type        = string
  default     = "8"
}
