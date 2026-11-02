terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Las credenciales NO se escriben aqui: se toman de ~/.aws/credentials
# (AWS Details > AWS CLI en el Learner Lab) o de variables de entorno en el pipeline.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Course      = "DGITI"
    }
  }
}
