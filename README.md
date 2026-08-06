# Infraestructura — SitioWeb Digital

Terraform + Ansible para levantar, en AWS (o en cualquier otra máquina con
SSH y Ubuntu 22.04), el mismo servidor que teníamos antes con el runner
propio y los dos túneles de Cloudflare — pero reproducible desde cero en
vez de una máquina configurada a mano que, si se rompe, hay que volver a
armar recordando cada paso.

No toca el código de la app — [`frontend-sitio-web-digital`](https://github.com/sitio-web-digital/frontend-sitio-web-digital)
y [`backend-sitio-web-digital`](https://github.com/sitio-web-digital/backend-sitio-web-digital)
siguen siendo sus propios repos, con sus propios workflows de deploy
(`deploy-frontend.yml` / `deploy-backend.yml`). Este repo solo prepara la
**máquina** donde esos workflows corren.

## Qué arma

```
                                 Internet
                                    │
                     ┌──────────────┴──────────────┐
                     │        Cloudflare            │
                     │  (termina TLS, hace de CDN)   │
                     └───────┬───────────────┬──────┘
                    túnel "frontend"    túnel "api"
                             │                 │
   ┌─────────────────────────┴─────────────────┴──────────────────────┐
   │  EC2 (Ubuntu 22.04, t3.medium, sa-east-1)                        │
   │                                                                   │
   │   cloudflared-frontend.service  →  localhost:8081  (nginx)        │
   │   cloudflared-api.service       →  localhost:4000  (Node/Express) │
   │                                                                   │
   │   docker: sitioweb-frontend, sitioweb-backend, sitiowebdigital-db │
   │   (los dos primeros los levanta el runner en cada deploy;         │
   │    el tercero — Postgres — lo levanta este mismo playbook)        │
   │                                                                   │
   │   actions.runner.sitio-web-digital.<host>.service                 │
   │   (un solo runner, nivel organización, atiende a ambos repos)     │
   └───────────────────────────────────────────────────────────────────┘
```

Ningún puerto de aplicación (80/443/4000/5435/8081) está expuesto a
internet directo — el Security Group de la instancia solo abre SSH, y todo
lo demás sale por los túneles salientes de Cloudflare. Esto es **más
seguro** que si el servidor original tenía 80/443 abiertos.

## Qué NO automatiza (a propósito)

- **Los registros DNS de los túneles.** `cloudfordeploy.com` es una zona
  compartida con otros proyectos (ver `.env.production` del frontend) — un
  registro wildcard mal puesto puede pisar el subdominio de otro proyecto.
  `terraform/variables.tf` tiene `manage_dns = false` por defecto a
  propósito. Ver "DNS de los túneles" más abajo.
- **Los datos reales de Postgres del servidor viejo.** Este playbook deja
  una base de datos NUEVA y VACÍA (con el schema de `init.sql`, no los
  datos). Si todavía hay forma de sacar un `pg_dump` del servidor roto, ver
  "Migrar los datos del servidor anterior" más abajo.
- **Las fotos que quedaron solo en `/uploads` del servidor viejo** (antes
  de que el backend migrara a subir todo a S3 — ver
  `server/src/routes/uploads.js`). Si hacen falta, migrarlas a mano al
  bucket S3.
- **Rotar credenciales existentes.** Ver "Nota de seguridad" abajo.

## Prerequisitos

- **Terraform** >= 1.5 (funciona bien en Windows/Mac/Linux).
- **Ansible** — necesita un control node Linux/Mac (o WSL en Windows).
  `ansible-core` usa `fcntl`, que no existe en Python de Windows nativo.
  Todo este README asume que corrés los comandos de `ansible/` desde WSL,
  Linux o Mac.
- **AWS CLI** configurado con credenciales que puedan crear EC2/IAM/EIP
  (`aws configure`, o variables `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
  `AWS_SESSION_TOKEN`).
- Una cuenta de **Cloudflare** con la zona `cloudfordeploy.com` (o la que
  uses) ya agregada, y un **API Token** con permiso
  `Account > Cloudflare Tunnel > Edit` (sumá `Zone > DNS > Edit` si vas a
  usar `manage_dns = true`).
- Un **Personal Access Token de GitHub** (classic) con scope `admin:org`,
  de alguien con permisos de administrador en la organización
  `sitio-web-digital` — se usa una sola vez para registrar el runner (ver
  abajo, se puede revocar después).
- Tu clave pública SSH (`~/.ssh/id_ed25519.pub` o similar).

## Bootstrap de punta a punta

### 1. Provisionar la máquina (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# completá terraform.tfvars con tu IP pública, el API token de Cloudflare, etc.

terraform init
terraform plan   # revisar qué va a crear antes de aplicar
terraform apply
```

Esto crea la instancia EC2 + Elastic IP + Security Group + rol IAM, y del
lado de Cloudflare los dos objetos "túnel" (todavía sin tráfico real
llegando, porque cloudflared no está instalado ni corriendo en la máquina
todavía — eso lo hace Ansible en el paso 3).

### 2. Generar el inventario de Ansible

```bash
cd ../ansible
./scripts/generate-inventory.sh   # lee la IP de `terraform output` y arma inventory/hosts.ini
```

### 3. Completar los secretos (Ansible Vault)

```bash
cp group_vars/vault.yml.example group_vars/vault.yml
# completá group_vars/vault.yml: el PAT del runner, la contraseña de
# Postgres, el JWT secret (openssl rand -base64 48), Mercado Pago, etc.

./scripts/fetch-tunnel-tokens.sh   # copia los tokens de los túneles desde `terraform output`

ansible-vault encrypt group_vars/vault.yml
echo "tu-contraseña-del-vault" > .vault_pass && chmod 600 .vault_pass
```

`group_vars/vault.yml` ya encriptado SÍ va al repo (es justamente lo que
permite reproducir esto en otra máquina) — `.vault_pass` (la contraseña que
lo abre) NUNCA. Guardala en un gestor de contraseñas del equipo.

### 4. Correr el playbook

```bash
ansible-playbook playbook.yml --vault-password-file .vault_pass
```

Deja instalados y corriendo: Docker, Postgres (vacío, con el schema
inicial), el runner de GitHub Actions como servicio systemd, los dos
túneles de Cloudflare, y `/opt/sitioweb/backend.env`.

Es **idempotente** — correrlo de nuevo (por ejemplo después de rotar un
secreto en `vault.yml`) no rompe nada, solo aplica lo que cambió.

### 5. Confirmar que el runner apareció

`https://github.com/organizations/sitio-web-digital/settings/actions/runners`
— debería verse un runner online con los labels
`self-hosted, linux, x64, aws`. A partir de acá, un push a `develop` en
cualquiera de los dos repos dispara su workflow de deploy normal, igual que
antes.

### 6. Primer deploy

Pusheá (o volvé a correr) `deploy-backend.yml` y `deploy-frontend.yml` — el
runner nuevo va a hacer `docker build` + `docker run` igual que el viejo.
El backend va a fallar si `/opt/sitioweb/backend.env` no existe — pero el
paso 4 ya lo creó.

## DNS de los túneles

Con `manage_dns = false` (default), después del `apply` los túneles
existen en Cloudflare pero nada apunta todavía a
`sitiowebdigital.cloudfordeploy.com` / `api-dev.cloudfordeploy.com`. Dos
opciones:

- **A mano** (recomendado la primera vez, para revisar la zona compartida
  antes): Cloudflare Dashboard > la zona > DNS > agregar un CNAME a
  `<tunnel-id>.cfargotunnel.com` (el ID sale de
  `terraform output cloudflare_tunnel_id_frontend` / `_api`), proxied
  (nube naranja).
- **Con Terraform**, una vez confirmado que no pisa nada: poné
  `manage_dns = true` y completá `cloudflare_zone_id` en
  `terraform.tfvars`, `terraform apply` de nuevo.

## Migrar los datos del servidor anterior

Este repo deja Postgres **vacío** (solo el schema). Si el servidor viejo
todavía prende o tenés un backup:

```bash
# en el servidor viejo (o restaurando un backup ahí)
pg_dump -U sitioweb -d sitioweb_digital -Fc -f sitioweb_digital.dump

# copiarlo al servidor nuevo y restaurar
scp sitioweb_digital.dump ubuntu@<ip-nueva>:/tmp/
ssh ubuntu@<ip-nueva>
docker exec -i sitiowebdigital-db pg_restore -U sitioweb -d sitioweb_digital --clean --if-exists < /tmp/sitioweb_digital.dump
```

## Día a día

- **Cambiar un secreto** (ej. rotar `MP_ACCESS_TOKEN`): editar
  `group_vars/vault.yml` (`ansible-vault edit group_vars/vault.yml
  --vault-password-file .vault_pass`) y volver a correr
  `ansible-playbook playbook.yml --vault-password-file .vault_pass`.
- **Agregar acceso SSH a alguien más**: sumar su IP a
  `allowed_ssh_cidrs` en `terraform.tfvars` y `terraform apply`, o usar
  `aws ssm start-session --target <instance-id>` (el rol IAM ya tiene
  `AmazonSSMManagedInstanceCore`, no hace falta abrir el Security Group
  para eso).
- **Reinstalar el runner desde cero** (ej. cambió el nombre del host):
  borrar `/opt/actions-runner/.runner` en la máquina y volver a correr el
  playbook — pero primero sacá el runner viejo (offline) desde la
  configuración de la organización en GitHub, o `config.sh --unattended`
  va a fallar si ya existe uno con ese nombre.
- **Destruir todo**: `cd terraform && terraform destroy` — esto NO borra
  los túneles si tenés registros DNS manuales apuntando a ellos por fuera
  de Terraform; sacalos a mano del dashboard de Cloudflare antes si hace
  falta.

## Backend remoto de estado (Terraform)

Por ahora el estado (`terraform.tfstate`) queda local, gitignoreado — bien
para una sola persona. Si el equipo crece, migrar a un backend S3
(+ DynamoDB para el lock) agregando un bloque `backend "s3" {}` en
`versions.tf` y corriendo `terraform init -migrate-state`.

## Nota de seguridad

Al armar este repo se encontró `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
y `CLOUDFLARE_API_TOKEN` en texto plano en `server/.env` del backend (no
están en el historial de git, el archivo está bien gitignoreado, pero
vivían así en el filesystem del servidor viejo). Con este setup nuevo esa
access key de AWS **ya no hace falta** — el backend usa el rol IAM de la
instancia (ver `terraform/iam.tf`, permiso mínimo: `s3:PutObject` solo
sobre `uploads/*` del bucket). Vale la pena rotar esa access key y el token
de Cloudflare igual, ya que estuvieron expuestos en texto plano.
