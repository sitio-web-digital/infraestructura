# Solo SSH entra por IP pública — el frontend (8081), la API (4000) y
# Postgres (5435) nunca necesitan un puerto abierto a internet: cloudflared
# abre las dos conexiones salientes hacia Cloudflare (el "túnel") y es
# Cloudflare quien expone sitiowebdigital.cloudfordeploy.com / api-dev.* al
# público, terminando TLS de su lado. Esto es más seguro que el setup
# original si ese tenía 80/443 abiertos directo en el servidor.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "SSH restringido + todo el resto sale por Cloudflare Tunnel (nada entra por HTTP/HTTPS directo)"
  vpc_id      = data.aws_vpc.default.id

  # AWS solo permite ASCII basico en la descripcion de reglas (sin acentos
  # ni guiones largos) - por eso estas dos van sin tildes, a diferencia del
  # resto de los comentarios de este repo.
  ingress {
    description = "SSH (administracion/Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "Todo el trafico saliente (Docker Hub, apt, GitHub, Cloudflare, S3, Mercado Pago, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}
