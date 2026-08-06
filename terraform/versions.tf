terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Estado local por defecto (terraform.tfstate en esta carpeta, ver
  # .gitignore) — para un equipo de más de una persona conviene migrarlo a
  # un backend remoto (ej. S3 + DynamoDB para el lock). Ver README.md,
  # sección "Backend remoto de estado".
}

provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
