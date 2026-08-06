# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "Región de AWS. sa-east-1 (São Paulo) por defecto — misma región que el bucket S3 y el CloudFront ya existentes (sitiowebdigital-media), para minimizar latencia entre la app y el storage."
  type        = string
  default     = "sa-east-1"
}

variable "project_name" {
  description = "Nombre corto del proyecto, usado como prefijo de recursos y en tags."
  type        = string
  default     = "sitiowebdigital"
}

variable "environment" {
  description = "Nombre del ambiente (prod, staging, etc.) — usado en tags."
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "Tipo de instancia EC2. t3.medium (4 GB RAM) por defecto: corre Postgres + backend Node + nginx + un runner de GitHub Actions + 2 túneles de Cloudflare a la vez, t3.small (2 GB) queda muy justo."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Tamaño en GB del disco raíz (gp3)."
  type        = number
  default     = 30
}

variable "ssh_public_key_path" {
  description = "Ruta local a tu clave pública SSH (ej. ~/.ssh/id_ed25519.pub). Terraform la sube a AWS como key pair — la privada nunca sale de tu máquina ni pasa por acá."
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "Lista de CIDRs con permiso de entrada por SSH (puerto 22). Poné tu IP pública con /32 (ej. [\"200.45.12.8/32\"]) — NUNCA 0.0.0.0/0. El resto del tráfico (frontend, API) no necesita ningún puerto entrante: sale todo por los túneles de Cloudflare."
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "No uses 0.0.0.0/0 para SSH — restringilo a tu IP pública (o a una VPN/bastion) con /32."
  }
}

variable "s3_bucket_name" {
  description = "Nombre del bucket S3 de fotos YA EXISTENTE (sitiowebdigital-media). Terraform NO crea ni administra este bucket — solo le da permisos de escritura al rol de la instancia, para no arriesgar el bucket con datos reales de producción."
  type        = string
  default     = "sitiowebdigital-media"
}

variable "extra_tags" {
  description = "Tags adicionales a fusionar con los tags comunes de todos los recursos."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------

variable "cloudflare_api_token" {
  description = "API Token de Cloudflare (con permiso Account:Cloudflare Tunnel:Edit, y Zone:DNS:Edit si manage_dns = true). NUNCA lo pongas acá con un default — pasalo por terraform.tfvars (gitignoreado) o por la variable de entorno TF_VAR_cloudflare_api_token."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Account ID de Cloudflare (Dashboard > barra lateral derecha de cualquier zona)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID del dominio bajo el que viven los túneles (ej. cloudfordeploy.com). Solo hace falta si manage_dns = true."
  type        = string
  default     = ""
}

variable "manage_dns" {
  description = "Si Terraform crea los registros DNS de los túneles. Por defecto en false a propósito: cloudfordeploy.com es una zona COMPARTIDA con otros proyectos (ver .env.production del frontend), así que un registro wildcard mal puesto puede romper subdominios de otro proyecto. Dejalo en false y creá los registros a mano (o vía Terraform una vez confirmado que no pisa nada) hasta migrar a un dominio propio."
  type        = bool
  default     = false
}

variable "app_hostname" {
  description = "Hostname fijo de la app en sí (login, dashboard, editor) — distinto del wildcard de subdominios de cliente. Ver src/utils/rootDomain.js del frontend."
  type        = string
  default     = "sitiowebdigital.cloudfordeploy.com"
}

variable "customer_wildcard_hostname" {
  description = "Hostname wildcard para las páginas publicadas de cada cliente (<subdominio>.cloudfordeploy.com). Solo se usa si manage_dns = true."
  type        = string
  default     = "*.cloudfordeploy.com"
}

variable "api_hostname" {
  description = "Hostname del backend/API."
  type        = string
  default     = "api-dev.cloudfordeploy.com"
}
