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

variable "github_repo" {
  description = "Repo de GitHub (formato owner/nombre) autorizado a asumir el rol de CI vía OIDC — ver ci.tf."
  type        = string
  default     = "sitio-web-digital/infraestructura-sitio-web-digital-"
}

variable "tfstate_bucket_name" {
  description = "Bucket S3 del estado remoto (lo crea terraform/bootstrap/, no este módulo) — el rol de CI necesita permiso sobre él para poder leer/escribir el estado."
  type        = string
  default     = "sitiowebdigital-tfstate-269478442857"
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

variable "key_pair_name" {
  description = "Nombre del key pair de EC2 YA CREADO en AWS (ver README.md > \"Acceso SSH\" — se crea una sola vez con `aws ec2 create-key-pair` para poder bajar el .pem, Terraform no lo administra)."
  type        = string
  default     = "sitiowebdigital-prod"
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
  description = "Zone ID de sitioweb.digital (dominio propio, migrado de DonWeb el 2026-08-08 — ya no cloudfordeploy.com, esa zona compartida queda de lado)."
  type        = string
  default     = "5ca8bc07d777281e518637802c13e031"
}

variable "manage_dns" {
  description = "Si Terraform crea los registros DNS de los túneles. Ahora en true: sitioweb.digital es un dominio propio (ya no cloudfordeploy.com, la zona compartida con otros proyectos), así que Terraform puede manejar sus registros sin riesgo de pisar nada ajeno."
  type        = bool
  default     = true
}

variable "app_hostname" {
  description = "Hostname fijo de la app en sí (login, dashboard, editor) — distinto del wildcard de subdominios de cliente. Ver src/utils/rootDomain.js del frontend."
  type        = string
  default     = "app.sitioweb.digital"
}

variable "customer_wildcard_hostname" {
  description = "Hostname wildcard para las páginas publicadas de cada cliente (<subdominio>.sitioweb.digital). Un solo nivel (no algo como *.app.sitioweb.digital): el certificado gratis de Cloudflare solo cubre un nivel de wildcard."
  type        = string
  default     = "*.sitioweb.digital"
}

variable "api_hostname" {
  description = "Hostname del backend/API."
  type        = string
  default     = "api.sitioweb.digital"
}

variable "ses_domain" {
  description = "Dominio verificado en Amazon SES para mails transaccionales (ver server/src/utils/mail.js e iam.tf)."
  type        = string
  default     = "sitioweb.digital"
}

variable "mp_back_url_hostname" {
  description = "Hostname viejo (zona compartida cloudfordeploy.com) que se mantiene SOLO para el back_url de Mercado Pago — su validador rechaza el TLD .digital (probado en vivo, 2026-08-08). El registro DNS de este hostname ya existe (creado a mano, no lo administra Terraform); acá solo se agrega la regla de ingress del túnel."
  type        = string
  default     = "sitiowebdigital.cloudfordeploy.com"
}
