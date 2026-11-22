provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      Epic        = "Enterprise-AI-Platform"
      Initiative  = "ai-case-note-summaries"
      ManagedBy   = "Terraform"
    }
  }
}
