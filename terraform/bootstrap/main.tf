# Bootstrap del backend remoto de estado — se corre UNA SOLA VEZ, a mano,
# ANTES de usar terraform/ (el módulo principal). No lo dispara ningún
# workflow a propósito: si el pipeline de CI pudiera recrear el bucket que
# guarda su propio estado, un solo error de configuración podría dejar el
# estado real inaccesible. Este bootstrap se queda con estado LOCAL
# (bootstrap/terraform.tfstate, gitignoreado) — es la única parte de todo
# el repo que no vive en el backend remoto, porque es lo que lo crea.
#
# Uso:
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#   # copiar el nombre del bucket a terraform/versions.tf (backend "s3")

terraform {
  required_version = ">= 1.10.0" # necesita el locking nativo de S3 (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "sa-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  # Sufijo con el account ID para garantizar que el nombre del bucket sea
  # único globalmente (S3 comparte namespace entre TODAS las cuentas de AWS).
  bucket_name = "sitiowebdigital-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  tags = {
    Project   = "sitiowebdigital"
    ManagedBy = "terraform-bootstrap"
    Purpose   = "terraform-remote-state"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # poder recuperar un estado anterior si algo lo pisa mal
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value = aws_s3_bucket.state.id
}
