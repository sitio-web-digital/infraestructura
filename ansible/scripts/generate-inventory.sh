#!/usr/bin/env bash
# Genera ansible/inventory/hosts.ini a partir de la IP pública que salió de
# `terraform apply` — evita copiar la IP a mano y que se desactualice.
set -euo pipefail
cd "$(dirname "$0")/../.."

IP="$(cd terraform && terraform output -raw public_ip)"

cat > ansible/inventory/hosts.ini <<EOF
# Generado por scripts/generate-inventory.sh — no lo edites a mano.
[sitiowebdigital]
app ansible_host=${IP} ansible_user=ubuntu
EOF

echo "ansible/inventory/hosts.ini -> ${IP}"
