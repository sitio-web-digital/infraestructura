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
  # Renombrado el 2026-08-09 (de "infraestructura-sitio-web-digital-" a
  # "infraestructura") — el trust policy de ci.tf usa este valor para armar
  # el patrón del claim `sub` del token OIDC, así que quedó desactualizado
  # después del rename y terraform-apply.yml empezó a fallar en
  # "Could not assume role with OIDC: Not authorized to perform
  # sts:AssumeRoleWithWebIdentity" (confirmado en la corrida que disparó el
  # push de Matafuego SaaS). El fix en sí (actualizar el trust policy) hay
  # que aplicarlo con credenciales que NO sean el rol de CI — ese mismo rol
  # no tiene permiso de iam:UpdateAssumeRolePolicy sobre sí mismo, así que
  # una corrida de CI rota no puede autoarreglarse.
  default = "sitio-web-digital/infraestructura"
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

# ---------------------------------------------------------------------------
# Campus C4D (campus.cloudfordeploy.com) — panel comercial interno, otra app
# más en la MISMA instancia. cloudfordeploy.com es la zona compartida con
# otros proyectos (ver mp_back_url_hostname arriba) — por eso NO hay acá una
# variable de zone_id ni un recurso cloudflare_record: el túnel se crea por
# Terraform (es account-level, no toca ninguna zona), pero el CNAME de
# campus.cloudfordeploy.com se carga a mano en el dashboard de Cloudflare,
# mismo criterio que se usó siempre para esta zona compartida.
# ---------------------------------------------------------------------------

variable "campus_hostname" {
  description = "Hostname del panel comercial C4D (Node + SQLite, un solo contenedor)."
  type        = string
  default     = "campus.cloudfordeploy.com"
}

variable "campus_backend_port" {
  description = "Puerto local (en la instancia) donde escucha Campus. Distinto de backend_port/matafuego_backend_port porque los tres contenedores corren con --network host en la misma máquina."
  type        = number
  default     = 3000
}

# ---------------------------------------------------------------------------
# Matafuego SaaS (puntoco2.com) — segunda app en la MISMA instancia
# ---------------------------------------------------------------------------
# Comparte cuenta de Cloudflare con sitioweb.digital (misma cloudflare_account_id
# de arriba), pero puntoco2.com es una zona DISTINTA — de ahí un token y un
# zone_id propios acá, en vez de reusar cloudflare_zone_id/cloudflare_api_token.
# El token de acá solo necesita Zone:DNS:Edit sobre la zona de puntoco2.com; la
# creación del túnel en sí sigue usando el token de la cuenta (arriba), que ya
# tiene Account > Cloudflare Tunnel > Edit.

variable "puntoco2_cloudflare_api_token" {
  description = "API Token de Cloudflare con permiso Zone:DNS:Edit sobre la zona puntoco2.com (distinto del token de arriba, que es el de la cuenta). NUNCA con un default — pasalo por terraform.tfvars o TF_VAR_puntoco2_cloudflare_api_token."
  type        = string
  sensitive   = true
}

variable "puntoco2_cloudflare_zone_id" {
  description = "Zone ID de puntoco2.com (Cloudflare Dashboard > la zona > barra lateral derecha)."
  type        = string
  default     = "533bc36802755559ec3b71367424ea48"
}

variable "matafuego_api_hostname" {
  description = "Hostname del backend de Matafuego SaaS (Next.js, un solo repo con front+API)."
  type        = string
  default     = "api.puntoco2.com"
}

variable "matafuego_backend_port" {
  description = "Puerto local (en la instancia) donde escucha el backend de Matafuego. Distinto de backend_port (4000, ya usado por sitio web) porque los dos contenedores corren con --network host en la misma máquina."
  type        = number
  default     = 4001
}

variable "matafuego_frontend_hostname" {
  description = "Dominio único de Matafuego (zona apex) — landing (/home) y app (/login, todo lo demás) son rutas del MISMO Next.js que matafuego_api_hostname, no un deploy aparte. Ver el ingress en cloudflare.tf."
  type        = string
  default     = "puntoco2.com"
}

# ---------------------------------------------------------------------------
# Gestock (stock.cloudfordeploy.com) — cuarta app en la MISMA instancia.
# Mismo criterio que Campus: cloudfordeploy.com es la zona compartida (ver
# campus_hostname más arriba), así que acá tampoco hay una variable de
# zone_id ni un recurso cloudflare_record — el túnel se crea por Terraform,
# pero el CNAME de stock.cloudfordeploy.com se carga a mano en el dashboard
# de Cloudflare. Un solo contenedor sirve API (/api/*) y frontend estático
# al mismo tiempo (ver server/src/index.ts del repo gestock-app), por eso
# un solo hostname/puerto/túnel, igual que Campus.
# ---------------------------------------------------------------------------

variable "stock_hostname" {
  description = "Hostname del sistema de control de stock (Node + Fastify + Postgres, un solo contenedor sirve API y frontend)."
  type        = string
  default     = "stock.cloudfordeploy.com"
}

variable "stock_backend_port" {
  description = "Puerto local (en la instancia) donde escucha Gestock. Distinto de los otros tres (4000/4001/3000) porque los cuatro contenedores corren con --network host en la misma máquina."
  type        = number
  default     = 4002
}

# ---------------------------------------------------------------------------
# Farmacias del Sur (farmaciasdelsur.sitioweb.digital) — sexta app en la
# MISMA instancia. A diferencia de Campus/Gestock/Matafuego, vive en el
# dominio PROPIO (sitioweb.digital), no en la zona compartida
# cloudfordeploy.com — por eso acá SÍ hay un cloudflare_record (ver
# cloudflare.tf), gateado por manage_dns como app_hostname/api_hostname.
# ---------------------------------------------------------------------------

variable "farmacia_hostname" {
  description = "Hostname del sistema de farmacias (Next.js + Prisma + Postgres, monolito, un solo contenedor)."
  type        = string
  default     = "farmaciasdelsur.sitioweb.digital"
}

variable "farmacia_backend_port" {
  description = "Puerto local (en la instancia) donde escucha Farmacias del Sur. Distinto de los demás porque los contenedores corren con --network host en la misma máquina."
  type        = number
  default     = 4003
}
