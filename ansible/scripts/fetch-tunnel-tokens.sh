#!/usr/bin/env bash
# Copia los tokens de los túneles (salida sensible de terraform apply) a
# group_vars/all/vault.yml — para no tener que copiarlos a mano. Corré esto
# ANTES de encriptar vault.yml con ansible-vault; si ya está encriptado,
# desencriptalo primero con `ansible-vault decrypt group_vars/all/vault.yml`.
set -euo pipefail
cd "$(dirname "$0")/../.."

VAULT_FILE="ansible/group_vars/all/vault.yml"

if [ ! -f "$VAULT_FILE" ]; then
  echo "No existe $VAULT_FILE — copiá primero group_vars/all/vault.yml.example a vault.yml." >&2
  exit 1
fi

if grep -q '^\$ANSIBLE_VAULT' "$VAULT_FILE"; then
  echo "$VAULT_FILE está encriptado — corré 'ansible-vault decrypt $VAULT_FILE' primero." >&2
  exit 1
fi

FRONTEND_TOKEN="$(cd terraform && terraform output -raw cloudflare_tunnel_token_frontend)"
API_TOKEN="$(cd terraform && terraform output -raw cloudflare_tunnel_token_api)"

sed -i \
  -e "s|^vault_cloudflare_tunnel_token_frontend:.*|vault_cloudflare_tunnel_token_frontend: \"${FRONTEND_TOKEN}\"|" \
  -e "s|^vault_cloudflare_tunnel_token_api:.*|vault_cloudflare_tunnel_token_api: \"${API_TOKEN}\"|" \
  "$VAULT_FILE"

echo "Tokens de los túneles copiados a $VAULT_FILE."
echo "Ahora encriptalo: ansible-vault encrypt $VAULT_FILE"
