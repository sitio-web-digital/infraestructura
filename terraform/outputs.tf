output "instance_id" {
  description = "ID de la instancia EC2."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "IP pública fija (Elastic IP) — usarla en ansible/inventory/hosts.ini."
  value       = aws_eip.app.public_ip
}

output "ssh_command" {
  description = "Comando para probar la conexión SSH manualmente."
  value       = "ssh ubuntu@${aws_eip.app.public_ip}"
}

output "cloudflare_tunnel_id_frontend" {
  description = "ID del túnel de frontend (nginx, :8081)."
  value       = cloudflare_zero_trust_tunnel_cloudflared.frontend.id
}

output "cloudflare_tunnel_id_api" {
  description = "ID del túnel de la API (backend, :4000)."
  value       = cloudflare_zero_trust_tunnel_cloudflared.api.id
}

# Sensibles: no se imprimen en la salida normal de `terraform apply`, solo
# con `terraform output -raw <nombre>`. Ansible los toma a través de
# ansible/scripts/fetch-tunnel-tokens.sh (ver README), no hace falta
# copiarlos a mano.
output "cloudflare_tunnel_token_frontend" {
  description = "Token para `cloudflared service install <token>` del túnel de frontend."
  value       = local.tunnel_token_frontend
  sensitive   = true
}

output "cloudflare_tunnel_token_api" {
  description = "Token para `cloudflared service install <token>` del túnel de la API."
  value       = local.tunnel_token_api
  sensitive   = true
}

output "cloudflare_tunnel_id_matafuego_api" {
  description = "ID del túnel del backend de Matafuego SaaS (puntoco2) — ver matafuego_backend_port para el puerto."
  value       = cloudflare_zero_trust_tunnel_cloudflared.matafuego_api.id
}

output "cloudflare_tunnel_token_matafuego_api" {
  description = "Token para `cloudflared service install <token>` del túnel de Matafuego."
  value       = local.tunnel_token_matafuego_api
  sensitive   = true
}

