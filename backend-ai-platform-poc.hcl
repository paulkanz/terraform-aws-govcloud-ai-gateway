bucket         = "terraform-state-123456789012"
key            = "ai-platform/poc/terraform.tfstate"
region         = "us-gov-west-1"
encrypt        = true
dynamodb_table = "terraform-state-lock"
