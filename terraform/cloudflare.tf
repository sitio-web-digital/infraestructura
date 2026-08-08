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

  # Las reglas de ingress son ruteo INTERNO del túnel — no crean ni tocan
  # ningún registro DNS de nadie, así que van siempre, sin atarlas a
  # manage_dns (esa variable es solo para si Terraform crea el registro
  # DNS en sí; el CNAME de cada hostname puede perfectamente existir ya,
  # creado a mano — de hecho así quedó la primera vez: los 4 hostnames de
  # esta app ya existían en la zona compartida desde el servidor viejo, y
  # se actualizaron a mano para apuntar a los túneles nuevos en vez de
  # crearlos de cero).
  config {
    ingress_rule {
      hostname = var.app_hostname
      service  = "http://localhost:8081"
    }
    ingress_rule {
      hostname = var.customer_wildcard_hostname
      service  = "http://localhost:8081"
    }
    # Mercado Pago rechaza el back_url de la suscripción si el dominio
    # termina en ".digital" (probado en vivo, 2026-08-08: hasta con el sitio
    # viejo de DonWeb en ese TLD, sin túnel de por medio, tira "Invalid value
    # for back_url" — no es cosa nuestra, alguna lista de TLDs de su lado).
    # Mientras dure eso, MP_BACK_URL (ver server/.env / Ansible) sigue
    # apuntando acá — mismo hostname viejo, mismo servicio, solo para que
    # el link de retorno post-pago funcione.
    ingress_rule {
      hostname = var.mp_back_url_hostname
      service  = "http://localhost:8081"
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
# Migrado el 2026-08-08: sitioweb.digital es un dominio PROPIO (antes vivía
# en cloudfordeploy.com, una zona compartida con otros proyectos, de ahí el
# cuidado de antes con el wildcard). Ya no aplica ese riesgo — manage_dns
# quedó en true. Ojo igual: la zona sí tiene registros previos del dominio
# (mail/ftp/autoconfig/autodiscover/MX/SPF/DKIM del hosting viejo en DonWeb)
# que Terraform NO administra — solo toca app/api/el wildcard de clientes.
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
