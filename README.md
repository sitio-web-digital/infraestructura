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
   │   actions.runner.sitio-web-digital-frontend-....service           │
   │   actions.runner.sitio-web-digital-backend-....service            │
   │   (un runner por repo — ver nota sobre membership de la org)      │
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
  de alguien con acceso de administrador sobre los dos repos
  (`frontend-sitio-web-digital` y `backend-sitio-web-digital`) — se usa una
  sola vez para registrar el runner (ver abajo, se puede revocar después).
  Registra un runner por REPO, no uno solo a nivel organización — pedir el
  registro a nivel org (`POST /orgs/{org}/actions/runners/registration-token`)
  devuelve 404 si la cuenta del token no figura como *miembro* de la
  organización (tener acceso a los repos como colaborador no alcanza). Si
  en algún momento esa cuenta pasa a ser miembro de la org, se puede
  simplificar a un solo runner — ver el comentario en
  `ansible/roles/github_runner/tasks/main.yml`.

## Acceso SSH (key pair)

Terraform NO crea el key pair — así se puede bajar la clave privada una
sola vez al crearlo (si Terraform lo manejara como recurso, la clave
privada nunca sale de la API de AWS). Ya está creado para este proyecto
(`sitiowebdigital-prod`, región `sa-east-1`); si hay que rehacerlo desde
cero en otra cuenta:

```bash
aws ec2 create-key-pair \
  --region sa-east-1 \
  --key-name sitiowebdigital-prod \
  --key-type ed25519 \
  --key-format pem \
  --query "KeyMaterial" \
  --output text > sitiowebdigital-prod.pem
chmod 400 sitiowebdigital-prod.pem
```

**Guardá ese `.pem` en un lugar seguro apenas lo bajes** (gestor de
contraseñas del equipo, vault) — AWS no se queda con una copia; si se
pierde, no hay forma de recuperarlo, solo de crear un key pair nuevo (y
reasignarlo a la instancia). Con la clave a mano:

```bash
ssh -i sitiowebdigital-prod.pem ubuntu@<ip-de-la-instancia>
```

## Bootstrap de punta a punta

### 0. Backend remoto de estado (una sola vez)

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Crea el bucket S3 donde vive el `terraform.tfstate` de todo lo demás
(versionado, encriptado, sin acceso público) — ya está creado para este
proyecto (`sitiowebdigital-tfstate-269478442857`). Sin este paso, ni vos ni
el workflow de CI tienen dónde guardar el estado entre corridas. Ver
"Backend remoto de estado" más abajo para el porqué de este paso aparte.

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
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
# completá group_vars/all/vault.yml: el PAT del runner, la contraseña de
# Postgres, el JWT secret (openssl rand -base64 48), Mercado Pago, etc.

./scripts/fetch-tunnel-tokens.sh   # copia los tokens de los túneles desde `terraform output`

ansible-vault encrypt group_vars/all/vault.yml
echo "tu-contraseña-del-vault" > .vault_pass && chmod 600 .vault_pass
```

Nota: tiene que vivir en `group_vars/all/` (no `group_vars/` a secas) — Ansible
solo auto-carga `group_vars/all.yml` o una carpeta `group_vars/all/` completa,
no cualquier archivo suelto ahí adentro.

`group_vars/all/vault.yml` ya encriptado SÍ va al repo (es justamente lo que
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
  `group_vars/all/vault.yml` (`ansible-vault edit group_vars/all/vault.yml
  --vault-password-file .vault_pass`) y volver a correr
  `ansible-playbook playbook.yml --vault-password-file .vault_pass`.
- **Agregar acceso SSH a alguien más**: sumar su IP a
  `allowed_ssh_cidrs` en `terraform.tfvars` y `terraform apply`, o usar
  `aws ssm start-session --target <instance-id>` (el rol IAM ya tiene
  `AmazonSSMManagedInstanceCore`, no hace falta abrir el Security Group
  para eso).
- **Reinstalar un runner desde cero** (ej. cambió el nombre del host):
  borrar `/opt/actions-runner-<frontend|backend>/.runner` en la máquina y
  volver a correr el playbook — pero primero sacá el runner viejo (offline)
  desde Settings > Actions > Runners de ESE repo puntual en GitHub, o
  `config.sh --unattended` va a fallar si ya existe uno con ese nombre.
- **Destruir todo**: `cd terraform && terraform destroy` — esto NO borra
  los túneles si tenés registros DNS manuales apuntando a ellos por fuera
  de Terraform; sacalos a mano del dashboard de Cloudflare antes si hace
  falta.

## CI: los dos workflows de Terraform

`.github/workflows/terraform-plan.yml` y `terraform-apply.yml` corren en
runners de GitHub (`ubuntu-latest`) — **no** en el self-hosted que vive
dentro de la infraestructura que ellos mismos administran, para que un
`apply`/`destroy` no pueda tirar abajo al runner que lo está corriendo.

- **`terraform-plan.yml`** — en cada Pull Request que toque `terraform/**`,
  corre `fmt -check` + `validate` + `plan`, y comenta el resultado en el
  PR. Nunca aplica nada.
- **`terraform-apply.yml`** — en cada push a `main` (o a mano, escribiendo
  "apply" en el input de `workflow_dispatch`), corre `terraform apply
  -auto-approve`. Usa un `environment: production` — activá "Required
  reviewers" en Settings > Environments > production del repo para que
  alguien tenga que aprobar antes de que aplique de verdad.

Autenticación a AWS por **OIDC, sin access key** (ver `terraform/ci.tf`):
GitHub le pide un token de corta duración a AWS en cada corrida, a cambio
de credenciales temporales — no hay ningún secreto de AWS permanente
guardado en el repo. El rol (`sitiowebdigital-prod-github-actions`) ya está
creado y solo puede tocar recursos con el tag `Project=sitiowebdigital` (o
con ese prefijo en el nombre, para IAM) — nada del resto de esta cuenta de
AWS, que es compartida con otros proyectos.

**Secrets que hay que cargar en el repo** (Settings > Secrets and
variables > Actions):

| Secret | Valor |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::269478442857:role/sitiowebdigital-prod-github-actions` (ya existe, ver `terraform output github_actions_role_arn`) |
| `CLOUDFLARE_API_TOKEN` | el mismo token de `terraform.tfvars` |
| `CLOUDFLARE_ACCOUNT_ID` | el mismo de `terraform.tfvars` |
| `ALLOWED_SSH_CIDRS` | ej. `["200.45.12.8/32"]` — tu IP pública |

## Backend remoto de estado (Terraform)

El estado vive en S3 (`sitiowebdigital-tfstate-269478442857`, ver
`terraform/versions.tf` y `terraform/bootstrap/`), no local — hace falta
así para que el workflow de `terraform-apply.yml` funcione: cada corrida de
CI arranca sin nada en disco, así que si el estado quedara solo en tu
máquina, la CI "olvidaría" en cada corrida lo que ya existe y trataría de
recrear todo de cero. El lock (para que dos `apply` no se pisen) usa el
locking nativo de S3 (`use_lockfile`, Terraform >= 1.10) — no hace falta
una tabla de DynamoDB aparte.

## Nota de seguridad

Al armar este repo se encontró `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
y `CLOUDFLARE_API_TOKEN` en texto plano en `server/.env` del backend (no
están en el historial de git, el archivo está bien gitignoreado, pero
vivían así en el filesystem del servidor viejo). Con este setup nuevo esa
access key de AWS **ya no hace falta** — el backend usa el rol IAM de la
instancia (ver `terraform/iam.tf`, permiso mínimo: `s3:PutObject` solo
sobre `uploads/*` del bucket). Vale la pena rotar esa access key y el token
de Cloudflare igual, ya que estuvieron expuestos en texto plano.
