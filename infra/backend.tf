terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "solidarytech-terraform-state-260717-4ad278"
    key          = "hackathon-dclt/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  # Política de tags obrigatória — aplicada globalmente a TODOS os recursos que
  # suportam tagging. Centralizar aqui (em vez de repetir por recurso) garante
  # que nenhum recurso novo escape da política e evita divergência de valores
  # (ex: "production" vs "Production"). Tags específicas de recurso (Name,
  # Service) continuam nos módulos e são mescladas com estas.
  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Production"
      CostCenter  = "NGO-Core"
    }
  }
}
