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

# --- Matafuego SaaS (puntoco2.com) ------------------------------------------
# Tercer túnel, mismo patrón que "api" — su propio servicio systemd
# (cloudflared-matafuego-api, ver ansible/roles/cloudflared) corriendo en la
# MISMA instancia que sitio web, sin pisar nada de los otros dos túneles.
# Usa el provider alias "puntoco2" (token propio, confirmado con permiso de
# Cloudflare Tunnel sobre la cuenta) para TODO este bloque — tunel, config e
# ingress incluidos, no solo el registro DNS — así no depende en nada del
# token original de sitio web.

resource "random_id" "tunnel_secret_matafuego_api" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "matafuego_api" {
  provider   = cloudflare.puntoco2
  account_id = var.cloudflare_account_id
  name       = "${local.name}-matafuego-api"
  secret     = random_id.tunnel_secret_matafuego_api.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "matafuego_api" {
  provider   = cloudflare.puntoco2
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.matafuego_api.id

  config {
    ingress_rule {
      hostname = var.matafuego_api_hostname
      service  = "http://localhost:${var.matafuego_backend_port}"
    }
    # Mismo servicio Next.js que matafuego_api_hostname (un solo repo,
    # front+API juntos) — "app." es el nombre que va a ver el usuario final,
    # "api." queda para uso técnico/integraciones. Dos hostnames, un mismo
    # puerto.
    ingress_rule {
      hostname = var.matafuego_app_hostname
      service  = "http://localhost:${var.matafuego_backend_port}"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Cuarto túnel: la landing de puntoco2.com (repo aparte, todavía sin
# desplegar). Se prepara el túnel/ingress/DNS ahora para que cuando el sitio
# exista, desplegarlo sea solo levantar un contenedor en matafuego_frontend_port
# — sin tocar Cloudflare de nuevo. cloudflared va a correr igual (systemd,
# ver ansible/roles/cloudflared) devolviendo 502 hasta que algo escuche ahí,
# mismo bootstrapping que tuvieron frontend/api de sitio web al principio.
resource "random_id" "tunnel_secret_matafuego_frontend" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "matafuego_frontend" {
  provider   = cloudflare.puntoco2
  account_id = var.cloudflare_account_id
  name       = "${local.name}-matafuego-frontend"
  secret     = random_id.tunnel_secret_matafuego_frontend.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "matafuego_frontend" {
  provider   = cloudflare.puntoco2
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.matafuego_frontend.id

  config {
    ingress_rule {
      hostname = var.matafuego_frontend_hostname
      service  = "http://localhost:${var.matafuego_frontend_port}"
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
  tunnel_token_matafuego_api = base64encode(jsonencode({
    a = var.cloudflare_account_id
    t = cloudflare_zero_trust_tunnel_cloudflared.matafuego_api.id
    s = random_id.tunnel_secret_matafuego_api.b64_std
  }))
  tunnel_token_matafuego_frontend = base64encode(jsonencode({
    a = var.cloudflare_account_id
    t = cloudflare_zero_trust_tunnel_cloudflared.matafuego_frontend.id
    s = random_id.tunnel_secret_matafuego_frontend.b64_std
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

# Zona distinta (puntoco2.com, no sitioweb.digital) → provider alias con el
# token propio de esa zona (ver versions.tf y variables.tf).
resource "cloudflare_record" "matafuego_api" {
  count    = var.manage_dns ? 1 : 0
  provider = cloudflare.puntoco2
  zone_id  = var.puntoco2_cloudflare_zone_id
  name     = var.matafuego_api_hostname
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.matafuego_api.id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
}

resource "cloudflare_record" "matafuego_app" {
  count    = var.manage_dns ? 1 : 0
  provider = cloudflare.puntoco2
  zone_id  = var.puntoco2_cloudflare_zone_id
  name     = var.matafuego_app_hostname
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.matafuego_api.id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
}

# Zona apex (puntoco2.com, no un subdominio) — Cloudflare soporta CNAME acá
# via "flattening" automático en el borde mientras el registro esté
# proxiado (nube naranja), no hace falta un A record aparte.
resource "cloudflare_record" "matafuego_frontend" {
  count    = var.manage_dns ? 1 : 0
  provider = cloudflare.puntoco2
  zone_id  = var.puntoco2_cloudflare_zone_id
  name     = var.matafuego_frontend_hostname
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.matafuego_frontend.id}.cfargotunnel.com"
  type     = "CNAME"
  proxied  = true
}
