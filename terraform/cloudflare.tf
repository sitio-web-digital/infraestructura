# "Los dos túneles": uno para el frontend (nginx, puerto 8081) y otro para
# el backend/API (Node, puerto 4000). Cada uno corre como su propio servicio
# systemd en la instancia (ver ansible/roles/cloudflared) — así un túnel
# caído no tira abajo al otro, y cada uno tiene sus propias credenciales.
#
# Terraform crea acá el objeto "túnel" en Cloudflare (existe del lado de
# Cloudflare, no depende de la instancia) y le da a Ansible el token para
# correrlo. La RUTA DNS (el registro que hace que sitiowebdigital.cloudfordeploy.com
# apunte a este túnel) es un paso aparte, gateado por `manage_dns` — ver
# variables.tf y el comentario más abajo.

resource "random_id" "tunnel_secret_frontend" {
  byte_length = 35
}

resource "random_id" "tunnel_secret_api" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "frontend" {
  account_id = var.cloudflare_account_id
  name       = "${local.name}-frontend"
  secret     = random_id.tunnel_secret_frontend.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "api" {
  account_id = var.cloudflare_account_id
  name       = "${local.name}-api"
  secret     = random_id.tunnel_secret_api.b64_std
  config_src = "cloudflare"
}

# Ingress: a qué puerto local de la instancia manda el tráfico cada túnel.
# `http_status:404` de catch-all al final es obligatorio en cloudflared
# (Cloudflare lo exige como última regla).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "frontend" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.frontend.id

  config {
    ingress_rule {
      hostname = var.app_hostname
      service  = "http://localhost:8081"
    }
    dynamic "ingress_rule" {
      for_each = var.manage_dns ? [var.customer_wildcard_hostname] : []
      content {
        hostname = ingress_rule.value
        service  = "http://localhost:8081"
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "api" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.api.id

  config {
    ingress_rule {
      hostname = var.api_hostname
      service  = "http://localhost:4000"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Token que usa `cloudflared service install <token>` en la instancia. El
# provider de Cloudflare no expone un data source para pedirlo ya armado
# (eso es lo que hace `cloudflared tunnel token` contra la API) — pero el
# token conector es, literalmente, el account_id + tunnel_id + secret que ya
# definimos arriba, codificados como JSON en base64. Mismo formato que
# devuelve la API, construido acá para no depender de un data source que no
# existe. Sale tal cual para el playbook de Ansible (ver outputs.tf), NUNCA
# se escribe en este repo.
locals {
  tunnel_token_frontend = base64encode(jsonencode({
    a = var.cloudflare_account_id
    t = cloudflare_zero_trust_tunnel_cloudflared.frontend.id
    s = random_id.tunnel_secret_frontend.b64_std
  }))
  tunnel_token_api = base64encode(jsonencode({
    a = var.cloudflare_account_id
    t = cloudflare_zero_trust_tunnel_cloudflared.api.id
    s = random_id.tunnel_secret_api.b64_std
  }))
}

# --- DNS (opcional, ver variable manage_dns) --------------------------------
# cloudfordeploy.com es una zona COMPARTIDA con otros proyectos (así lo
# documenta .env.production del frontend). Un registro wildcard acá
# (*.cloudfordeploy.com) puede pisar subdominios de otro proyecto que viva
# en la misma zona si no se revisa antes. Por eso manage_dns nace en false:
# activalo solo después de confirmar en el dashboard de Cloudflare que nada
# más usa esos hostnames, o cuando se migre a un dominio propio
# (sitiowebdigital.com.ar).
resource "cloudflare_record" "app" {
  count   = var.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.app_hostname
  content = "${cloudflare_zero_trust_tunnel_cloudflared.frontend.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "customer_wildcard" {
  count   = var.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.customer_wildcard_hostname
  content = "${cloudflare_zero_trust_tunnel_cloudflared.frontend.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "api" {
  count   = var.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.api_hostname
  content = "${cloudflare_zero_trust_tunnel_cloudflared.api.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
