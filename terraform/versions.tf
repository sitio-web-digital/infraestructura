terraform {
  required_version = ">= 1.10.0" # el backend S3 usa el locking nativo (use_lockfile), sin DynamoDB

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

  # Estado remoto en S3 — el bucket lo crea terraform/bootstrap/ (se corre
  # una sola vez, a mano, antes de esto — ver README.md "Backend remoto de
  # estado"). Necesario para que terraform-apply.yml pueda correr desde
  # GitHub Actions: cada corrida de CI arranca sin nada en disco, así que el
  # estado tiene que vivir en otro lado o cada apply "olvida" lo que ya
  # existe. use_lockfile evita que dos applies pisen el estado al mismo
  # tiempo sin necesitar una tabla de DynamoDB aparte (Terraform >= 1.10).
  backend "s3" {
    bucket       = "sitiowebdigital-tfstate-269478442857"
    key          = "sitiowebdigital/terraform.tfstate"
    region       = "sa-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Alias para la zona de puntoco2.com — misma cuenta de Cloudflare, pero un
# token distinto (solo tiene permiso de DNS sobre ESA zona, no sobre la de
# sitioweb.digital). Ver el comentario en variables.tf.
provider "cloudflare" {
  alias     = "puntoco2"
  api_token = var.puntoco2_cloudflare_api_token
}
