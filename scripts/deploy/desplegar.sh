#!/usr/bin/env bash
# =============================================================================
# Carta Digital — despliegue automático (Docker + AWS) en un solo script.
#
#   Git (rama nueva) ─► Docker (contenedor) ─► AWS: RDS (Postgres)
#                                                   Load Balancer
#                                                   Auto Scaling
#                       Cloudflare (DNS/HTTPS) ◄── automático por API si
#                                                   CF_API_TOKEN/CF_ACCOUNT_ID/
#                                                   CF_SUBDOMAIN están en
#                                                   deploy.env; si no, imprime
#                                                   los pasos manuales.
#
# Uso (desde la raíz del repo, en AWS CloudShell, WSL o Git Bash):
#
#   cp scripts/deploy/deploy.env.example scripts/deploy/deploy.env   # y completarlo
#   bash scripts/deploy/desplegar.sh            # = "todo"
#
# Subcomandos (cada uno se puede correr suelto; todos son idempotentes:
# si un recurso ya existe, lo reutiliza en vez de duplicarlo):
#
#   verificar    revisa herramientas, credenciales de AWS, variables y la rama de Git
#   docker       construye la imagen y la prueba localmente (app + Postgres temporal)
#   red          security groups (ALB, app, RDS). El SG del ALB solo deja
#                entrar tráfico 80/443 desde los rangos de IP de Cloudflare
#                (se descargan de cloudflare.com en cada corrida), para que
#                nadie se salte el Worker pegándole directo al ALB.
#   base-datos   crea la instancia RDS PostgreSQL
#   app          Target Group + Load Balancer + Launch Template + Auto Scaling
#   cloudflare   automatiza Cloudflare por API (ver CF_* abajo), o si no
#                están esas variables, imprime los pasos manuales
#   estado       muestra el estado de RDS, el Auto Scaling y la salud en el ALB
#   todo         verificar → docker → red → base-datos → app → cloudflare
#   destruir     BORRA todo lo que creó este script, AWS y (si CF_API_TOKEN/
#                CF_ACCOUNT_ID están configurados) el Worker + KV namespace
#                de Cloudflare también. Pide confirmación.
#
# Variables útiles:
#   SALTAR_DOCKER=1          en "todo", omite la prueba local de Docker (ej. si
#                            estás en una máquina sin Docker).
#   RESTRINGIR_A_CLOUDFLARE=0  deja el ALB abierto a todo internet (0.0.0.0/0)
#                            en vez de restringirlo a IPs de Cloudflare. Útil
#                            para probar el ALB directo mientras depurás.
# =============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR_DEPLOY="$RAIZ/scripts/deploy"
CONFIG="${CONFIG:-$DIR_DEPLOY/deploy.env}"

# ------------------------------------------------------------------ utilidades
c_azul=$'\e[1;34m'; c_verde=$'\e[1;32m'; c_amarillo=$'\e[1;33m'; c_rojo=$'\e[1;31m'; c_fin=$'\e[0m'
paso()  { echo; echo "${c_azul}==> $*${c_fin}"; }
ok()    { echo "${c_verde}  ✔ $*${c_fin}"; }
aviso() { echo "${c_amarillo}  ! $*${c_fin}"; }
error() { echo "${c_rojo}  ✘ $*${c_fin}" >&2; exit 1; }

cargar_config() {
  [ -f "$CONFIG" ] || error "No existe $CONFIG. Copiá la plantilla: cp scripts/deploy/deploy.env.example scripts/deploy/deploy.env"
  # Normaliza finales de línea de Windows (CRLF) por si el archivo se editó en el Bloc de notas.
  # shellcheck disable=SC1090
  set -a; source <(sed 's/\r$//' "$CONFIG"); set +a

  AWS_REGION="${AWS_REGION:-us-east-1}"
  NAME_PREFIX="${NAME_PREFIX:-carta-digital}"
  INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
  ASG_MIN="${ASG_MIN:-1}"; ASG_DESIRED="${ASG_DESIRED:-2}"; ASG_MAX="${ASG_MAX:-4}"
  CPU_TARGET="${CPU_TARGET:-50}"
  RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-${NAME_PREFIX}-db}"
  RDS_ENGINE_VERSION="${RDS_ENGINE_VERSION:-17}"
  RDS_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t3.micro}"
  RDS_STORAGE_GB="${RDS_STORAGE_GB:-20}"
  RDS_MULTI_AZ="${RDS_MULTI_AZ:-false}"
  RDS_MASTER_USER="${RDS_MASTER_USER:-carta_admin}"
  DB_NAME="${DB_NAME:-carta_digital}"
  DB_USER="${DB_USER:-carta_app}"
  SESSION_SECURE_COOKIE="${SESSION_SECURE_COOKIE:-false}"
  GITHUB_TOKEN="${GITHUB_TOKEN:-}"

  # Cloudflare (opcional). Si las tres están completas, "cloudflare" automatiza
  # todo por API (crea el KV, publica el Worker, activa el subdominio) en vez
  # de solo imprimir los pasos manuales.
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
  CF_SUBDOMAIN="${CF_SUBDOMAIN:-}"
  CF_WORKER_NAME="${CF_WORKER_NAME:-${NAME_PREFIX}-proxy}"

  SG_ALB="${NAME_PREFIX}-alb-sg"
  SG_APP="${NAME_PREFIX}-app-sg"
  SG_RDS="${NAME_PREFIX}-rds-sg"
  TG_NAME="${NAME_PREFIX}-tg"
  ALB_NAME="${NAME_PREFIX}-alb"
  LT_NAME="${NAME_PREFIX}-lt"
  ASG_NAME="${NAME_PREFIX}-asg"
  DB_SUBNET_GROUP="${NAME_PREFIX}-subnet-group"

  export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
}

requerir() {
  local faltan=()
  for v in "$@"; do [ -n "${!v:-}" ] || faltan+=("$v"); done
  [ "${#faltan[@]}" -eq 0 ] || error "Faltan valores en $CONFIG: ${faltan[*]}"
}

# Devuelve el valor o vacío si AWS responde "None".
limpio() { local v; v="$(cat)"; [ "$v" = "None" ] && v=""; printf '%s' "$v"; }

# ------------------------------------------------------------------ lookups AWS
detectar_vpc() {
  if [ -z "${VPC_ID:-}" ]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
      --query 'Vpcs[0].VpcId' --output text | limpio)
    [ -n "$VPC_ID" ] || error "La cuenta no tiene VPC por defecto: definí VPC_ID en $CONFIG."
  fi
  SUBNETS=($(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query 'Subnets[].SubnetId' --output text))
  if [ "${#SUBNETS[@]}" -lt 2 ]; then
    # VPC no-default: usa cualquier subnet pública (que asigne IP pública).
    SUBNETS=($(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[].SubnetId' --output text))
  fi
  [ "${#SUBNETS[@]}" -ge 2 ] || error "Se necesitan al menos 2 subnets públicas (2 zonas) en $VPC_ID para el Load Balancer."
}

sg_id() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | limpio
}

# Agrega una regla de entrada ignorando el error "ya existe".
abrir_puerto() { # sg puerto (--cidr X | --source-group Y)
  local sg="$1" puerto="$2"; shift 2
  local salida
  if ! salida=$(aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port "$puerto" "$@" 2>&1); then
    echo "$salida" | grep -q "InvalidPermission.Duplicate" || { echo "$salida" >&2; exit 1; }
  fi
}

crear_sg() { # nombre descripcion -> imprime id
  local id; id=$(sg_id "$1")
  if [ -z "$id" ]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" \
      --vpc-id "$VPC_ID" --query GroupId --output text)
    aws ec2 create-tags --resources "$id" --tags "Key=Name,Value=$1" "Key=Proyecto,Value=$NAME_PREFIX"
  fi
  printf '%s' "$id"
}

# Quita una regla de entrada ignorando el error "no existe".
cerrar_puerto() { # sg puerto (--cidr X | --source-group Y)
  local sg="$1" puerto="$2"; shift 2
  local salida
  if ! salida=$(aws ec2 revoke-security-group-ingress --group-id "$sg" --protocol tcp --port "$puerto" "$@" 2>&1); then
    echo "$salida" | grep -q "InvalidPermission.NotFound" || { echo "$salida" >&2; exit 1; }
  fi
}

# Descarga los rangos de IP públicos de Cloudflare (IPv4 + IPv6).
# Se usan para que el ALB solo acepte tráfico que realmente viene de
# Cloudflare, en vez de aceptar cualquier IP de internet (0.0.0.0/0),
# lo que evita que alguien se salte el Worker (y su rate limiting/WAF)
# pegándole directo a la URL del Load Balancer.
ips_cloudflare() {
  local v4 v6
  v4=$(curl -fsS https://www.cloudflare.com/ips-v4) || error "No pude descargar https://www.cloudflare.com/ips-v4"
  v6=$(curl -fsS https://www.cloudflare.com/ips-v6) || error "No pude descargar https://www.cloudflare.com/ips-v6"
  printf '%s\n%s\n' "$v4" "$v6"
}

rds_endpoint() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null | limpio
}

alb_arn() {
  aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | limpio
}

alb_dns() {
  aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null | limpio
}

tg_arn() {
  aws elbv2 describe-target-groups --names "$TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | limpio
}

# =============================================================================
# 0) VERIFICAR
# =============================================================================
cmd_verificar() {
  paso "Verificando herramientas"
  command -v aws >/dev/null || error "Falta AWS CLI v2 (en CloudShell ya viene instalado)."
  ok "aws $(aws --version 2>&1 | cut -d' ' -f1)"
  if command -v docker >/dev/null; then ok "docker disponible"; else aviso "docker no está instalado: se saltará la prueba local del contenedor."; fi
  if [ -n "$CF_API_TOKEN" ]; then
    command -v jq >/dev/null && ok "jq disponible (para automatizar Cloudflare)" \
      || aviso "Falta 'jq': el paso de Cloudflare caerá a las instrucciones manuales."
  fi

  paso "Verificando credenciales de AWS (¿iniciaste sesión?)"
  local identidad
  identidad=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1) || error \
"No hay credenciales de AWS válidas. Opciones:
     a) Correr este script en AWS CloudShell (ya trae la sesión iniciada), o
     b) 'aws configure' con tu Access Key/Secret (y en AWS Academy, también el
        aws_session_token de 'AWS Details' → 'AWS CLI' en ~/.aws/credentials).
   Detalle: $identidad"
  ok "Cuenta/identidad: $identidad (región $AWS_REGION)"

  paso "Verificando variables de $CONFIG"
  requerir GITHUB_REPO GITHUB_BRANCH RDS_MASTER_PASSWORD DB_PASSWORD SESSION_SECRET
  [ "${#RDS_MASTER_PASSWORD}" -ge 8 ] || error "RDS_MASTER_PASSWORD debe tener al menos 8 caracteres."
  case "$RDS_MASTER_PASSWORD" in *[/@\"\ ]*) error "RDS_MASTER_PASSWORD no puede contener / @ \" ni espacios (regla de RDS).";; esac
  [ "${#SESSION_SECRET}" -ge 32 ] || aviso "SESSION_SECRET es corto; recomendado: openssl rand -hex 32"
  ok "Variables completas"

  paso "Verificando que la rama '$GITHUB_BRANCH' exista en $GITHUB_REPO"
  local url_git="$GITHUB_REPO"
  [ -z "${GITHUB_TOKEN:-}" ] || url_git="https://x-access-token:${GITHUB_TOKEN}@${GITHUB_REPO#https://}"
  if command -v git >/dev/null; then
    git ls-remote --exit-code --heads "$url_git" "$GITHUB_BRANCH" >/dev/null 2>&1 || error \
"No encontré la rama '$GITHUB_BRANCH' en el remoto (¿no existe, o el repo es privado y falta GITHUB_TOKEN?):
     git checkout -b $GITHUB_BRANCH && git push -u origin $GITHUB_BRANCH"
    ok "Rama encontrada (las instancias van a clonar esta rama)"
  else
    aviso "git no está instalado: no se pudo comprobar la rama."
  fi
}

# =============================================================================
# 1) DOCKER — construir la imagen y probarla localmente
# =============================================================================
cmd_docker() {
  command -v docker >/dev/null || { aviso "docker no disponible: salto la prueba local."; return 0; }
  local img="${NAME_PREFIX}:local" red="${NAME_PREFIX}-prueba" db="${NAME_PREFIX}-prueba-db" app="${NAME_PREFIX}-prueba-app"

  paso "Construyendo la imagen Docker ($img)"
  docker build -t "$img" "$RAIZ"
  ok "Imagen construida"

  paso "Probando el contenedor con un Postgres temporal"
  limpiar_prueba() { docker rm -f "$app" "$db" >/dev/null 2>&1 || true; docker network rm "$red" >/dev/null 2>&1 || true; }
  trap limpiar_prueba EXIT   # limpia aunque la prueba falle
  limpiar_prueba
  docker network create "$red" >/dev/null
  docker run -d --name "$db" --network "$red" \
    -e POSTGRES_DB=carta_digital -e POSTGRES_USER=carta_app -e POSTGRES_PASSWORD=prueba_local \
    -v "$RAIZ/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" postgres:17-alpine >/dev/null
  for _ in $(seq 1 30); do docker exec "$db" pg_isready -U carta_app -d carta_digital >/dev/null 2>&1 && break; sleep 2; done
  sleep 3   # el entrypoint reinicia Postgres una vez después de correr init.sql
  docker run -d --name "$app" --network "$red" \
    -e NODE_ENV=production -e PORT=3000 -e PGHOST="$db" -e PGPORT=5432 \
    -e PGDATABASE=carta_digital -e PGUSER=carta_app -e PGPASSWORD=prueba_local \
    -e SESSION_SECRET=solo_para_la_prueba_local_del_contenedor "$img" >/dev/null

  local sano=0
  for _ in $(seq 1 30); do
    if docker exec "$app" wget -qO- http://127.0.0.1:3000/health >/dev/null 2>&1 \
      && docker exec "$app" wget -qO- http://127.0.0.1:3000/api/restaurantes >/dev/null 2>&1; then sano=1; break; fi
    sleep 2
  done
  if [ "$sano" != 1 ]; then docker logs --tail 40 "$app" >&2; error "El contenedor no respondió /health ni /api/restaurantes."; fi
  ok "Contenedor sano: /health y /api/restaurantes responden"
  limpiar_prueba; trap - EXIT
}

# =============================================================================
# 2) RED — security groups
# =============================================================================
cmd_red() {
  detectar_vpc
  paso "Security groups en $VPC_ID"
  ALB_SG_ID=$(crear_sg "$SG_ALB" "ALB publico - Carta Digital")

  if [ "${RESTRINGIR_A_CLOUDFLARE:-1}" = "1" ]; then
    # Solo se acepta tráfico que venga de los rangos de IP de Cloudflare,
    # para que no se pueda saltar el Worker (y su rate limiting) pegándole
    # directo a la URL del ALB. Si por algún motivo ya existía la regla
    # abierta a todo internet (de una versión anterior del script), se quita.
    cerrar_puerto "$ALB_SG_ID" 80 --cidr 0.0.0.0/0
    cerrar_puerto "$ALB_SG_ID" 443 --cidr 0.0.0.0/0
    local n=0
    while IFS= read -r cidr; do
      [ -n "$cidr" ] || continue
      abrir_puerto "$ALB_SG_ID" 80 --cidr "$cidr"
      abrir_puerto "$ALB_SG_ID" 443 --cidr "$cidr"
      n=$((n+1))
    done < <(ips_cloudflare)
    ok "ALB: $ALB_SG_ID (80/443 solo desde IPs de Cloudflare, $n rangos)"
  else
    abrir_puerto "$ALB_SG_ID" 80 --cidr 0.0.0.0/0
    abrir_puerto "$ALB_SG_ID" 443 --cidr 0.0.0.0/0
    ok "ALB: $ALB_SG_ID (80/443 desde internet — RESTRINGIR_A_CLOUDFLARE=0)"
  fi

  APP_SG_ID=$(crear_sg "$SG_APP" "Instancias de la app - Carta Digital")
  abrir_puerto "$APP_SG_ID" 80 --source-group "$ALB_SG_ID"
  [ -n "${KEY_NAME:-}" ] && abrir_puerto "$APP_SG_ID" 22 --cidr 0.0.0.0/0
  ok "App: $APP_SG_ID (80 solo desde el ALB${KEY_NAME:+, 22 para SSH})"

  RDS_SG_ID=$(crear_sg "$SG_RDS" "RDS Postgres - Carta Digital")
  abrir_puerto "$RDS_SG_ID" 5432 --source-group "$APP_SG_ID"
  ok "RDS: $RDS_SG_ID (5432 solo desde las instancias de la app)"

  if [ -n "${EXISTING_INSTANCE_ID:-}" ]; then
    local sg_existente
    sg_existente=$(aws ec2 describe-instances --instance-ids "$EXISTING_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text | limpio)
    [ -n "$sg_existente" ] && abrir_puerto "$RDS_SG_ID" 5432 --source-group "$sg_existente" \
      && ok "RDS también accesible desde la instancia existente ($EXISTING_INSTANCE_ID)"
  fi
}

# =============================================================================
# 3) BASE DE DATOS — RDS PostgreSQL
# =============================================================================
cmd_base_datos() {
  [ -n "${RDS_SG_ID:-}" ] || cmd_red
  paso "DB Subnet Group"
  aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1 || \
    aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --db-subnet-group-description "Carta Digital RDS" --subnet-ids "${SUBNETS[@]}" >/dev/null
  ok "$DB_SUBNET_GROUP"

  paso "Instancia RDS PostgreSQL ($RDS_INSTANCE_ID)"
  if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null 2>&1; then
    ok "Ya existe, se reutiliza (los datos no se tocan)"
  else
    local multi_az="--no-multi-az"; [ "$RDS_MULTI_AZ" = "true" ] && multi_az="--multi-az"
    aws rds create-db-instance \
      --db-instance-identifier "$RDS_INSTANCE_ID" \
      --engine postgres --engine-version "$RDS_ENGINE_VERSION" \
      --db-instance-class "$RDS_INSTANCE_CLASS" \
      --allocated-storage "$RDS_STORAGE_GB" --storage-type gp3 \
      --master-username "$RDS_MASTER_USER" --master-user-password "$RDS_MASTER_PASSWORD" \
      --vpc-security-group-ids "$RDS_SG_ID" --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --no-publicly-accessible "$multi_az" --backup-retention-period 7 \
      --tags "Key=Proyecto,Value=$NAME_PREFIX" >/dev/null
    ok "Creación iniciada"
  fi
  echo "  Esperando a que RDS quede disponible (la primera vez tarda 5-10 min)..."
  aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"
  DB_HOST=$(rds_endpoint)
  ok "RDS lista: $DB_HOST"
  echo "  (El esquema y los datos iniciales los carga la primera instancia de la app al arrancar.)"
}

# =============================================================================
# 4) APP — user-data, Launch Template, Target Group, ALB, Auto Scaling
# =============================================================================
generar_user_data() { # archivo destino
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo 'exec > >(tee -a /var/log/carta-digital-userdata.log) 2>&1'
    echo '# --- valores inyectados por scripts/deploy/desplegar.sh ---'
    for v in GITHUB_REPO GITHUB_BRANCH GITHUB_TOKEN DB_HOST DB_NAME DB_USER DB_PASSWORD \
             RDS_MASTER_USER RDS_MASTER_PASSWORD SESSION_SECRET SESSION_SECURE_COOKIE; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    cat <<'CUERPO'

echo "== [1/5] Swap de 2 GB (el build de TypeScript/Vite no entra en 1 GB de RAM) =="
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "== [2/5] Docker + docker compose + git =="
dnf install -y docker git
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo "== [3/5] Código (rama $GITHUB_BRANCH) =="
rm -rf /opt/carta-digital
if [ -n "$GITHUB_TOKEN" ]; then
  # Repo privado: el token (solo lectura) se usa para clonar y se borra del remoto después.
  git clone --depth 1 --branch "$GITHUB_BRANCH" \
    "https://x-access-token:${GITHUB_TOKEN}@${GITHUB_REPO#https://}" /opt/carta-digital
  git -C /opt/carta-digital remote set-url origin "$GITHUB_REPO"
else
  git clone --depth 1 --branch "$GITHUB_BRANCH" "$GITHUB_REPO" /opt/carta-digital
fi
cd /opt/carta-digital

echo "== [4/5] Base de datos en RDS (crea rol/base y carga init.sql solo si está vacía) =="
psql_rds() { # contraseña, resto de argumentos de psql
  local clave="$1"; shift
  docker run --rm -e PGSSLMODE=require -e PGPASSWORD="$clave" \
    -v /opt/carta-digital/scripts/deploy/sql:/sql:ro -v /opt/carta-digital/db:/sql-db:ro \
    postgres:17-alpine psql -v ON_ERROR_STOP=1 -h "$DB_HOST" "$@"
}
psql_rds "$RDS_MASTER_PASSWORD" -U "$RDS_MASTER_USER" -d postgres \
  -v app_user="$DB_USER" -v app_pass="$DB_PASSWORD" -v app_db="$DB_NAME" -f /sql/01-rol-y-base.sql
psql_rds "$DB_PASSWORD" -U "$DB_USER" -d "$DB_NAME" -f /sql/02-esquema-si-vacia.sql

echo "== [5/5] Contenedor de la app (app-prod, puerto 80) =="
cat > .env.prod <<ENVEOF
NODE_ENV=production
PORT=80
PGHOST=$DB_HOST
PGPORT=5432
PGDATABASE=$DB_NAME
PGUSER=$DB_USER
PGPASSWORD=$DB_PASSWORD
PGSSL=true
SESSION_SECRET=$SESSION_SECRET
SESSION_SECURE_COOKIE=$SESSION_SECURE_COOKIE
ENVEOF
chmod 600 .env.prod
# docker compose valida el archivo completo: .env.dev/.env.qa solo tienen que existir.
touch .env.dev .env.qa
docker compose up -d --build app-prod
echo "== Listo: la app queda escuchando en :80 (/health) =="
CUERPO
  } > "$1"
}

cmd_app() {
  [ -n "${APP_SG_ID:-}" ] || cmd_red
  DB_HOST="${DB_HOST:-$(rds_endpoint)}"
  [ -n "$DB_HOST" ] || error "No encontré la RDS '$RDS_INSTANCE_ID'. Corré primero: desplegar.sh base-datos"
  requerir RDS_MASTER_PASSWORD DB_PASSWORD SESSION_SECRET GITHUB_REPO GITHUB_BRANCH

  if [ -z "${AMI_ID:-}" ]; then
    AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text 2>/dev/null | limpio) || true
    [ -n "$AMI_ID" ] || AMI_ID=$(aws ec2 describe-images --owners amazon \
      --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text | limpio)
    [ -n "$AMI_ID" ] || error "No pude detectar la AMI de Amazon Linux 2023: definí AMI_ID en $CONFIG."
  fi

  paso "Target Group (HTTP:80, healthcheck /health)"
  TG_ARN=$(tg_arn)
  if [ -z "$TG_ARN" ]; then
    TG_ARN=$(aws elbv2 create-target-group --name "$TG_NAME" --protocol HTTP --port 80 \
      --vpc-id "$VPC_ID" --target-type instance --health-check-path /health \
      --health-check-interval-seconds 15 --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
  fi
  ok "$TG_NAME"
  if [ -n "${EXISTING_INSTANCE_ID:-}" ]; then
    aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$EXISTING_INSTANCE_ID"
    ok "Instancia existente $EXISTING_INSTANCE_ID registrada"
  fi

  paso "Application Load Balancer"
  ALB_ARN=$(alb_arn)
  if [ -z "$ALB_ARN" ]; then
    ALB_ARN=$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application \
      --scheme internet-facing --subnets "${SUBNETS[@]}" --security-groups "$ALB_SG_ID" \
      --tags "Key=Proyecto,Value=$NAME_PREFIX" \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  fi
  local hay_listener
  hay_listener=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`80`].ListenerArn' --output text | limpio)
  [ -n "$hay_listener" ] || aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
  ok "$ALB_NAME → $(alb_dns)"

  paso "Launch Template (cada instancia nueva se instala sola con user-data)"
  local ud; ud=$(mktemp)
  generar_user_data "$ud"
  local linea_key=""
  [ -z "${KEY_NAME:-}" ] || linea_key="\"KeyName\": \"$KEY_NAME\","
  local datos_lt
  datos_lt=$(cat <<JSON
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  $linea_key
  "SecurityGroupIds": ["$APP_SG_ID"],
  "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled"},
  "TagSpecifications": [{"ResourceType": "instance", "Tags": [
    {"Key": "Name", "Value": "${NAME_PREFIX}-app"}, {"Key": "Proyecto", "Value": "$NAME_PREFIX"}]}],
  "UserData": "$(base64 -w0 "$ud" 2>/dev/null || base64 "$ud" | tr -d '\n')"
}
JSON
)
  rm -f "$ud"
  if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
    aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" \
      --launch-template-data "$datos_lt" >/dev/null
    aws ec2 modify-launch-template --launch-template-name "$LT_NAME" --default-version '$Latest' >/dev/null
    ok "$LT_NAME actualizado (nueva versión)"
    LT_ACTUALIZADO=1
  else
    aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
      --launch-template-data "$datos_lt" >/dev/null
    ok "$LT_NAME creado"
  fi

  paso "Auto Scaling Group (min $ASG_MIN / deseadas $ASG_DESIRED / max $ASG_MAX)"
  local existe
  existe=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text | limpio)
  if [ -z "$existe" ]; then
    aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
      --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Default" \
      --min-size "$ASG_MIN" --max-size "$ASG_MAX" --desired-capacity "$ASG_DESIRED" \
      --vpc-zone-identifier "$(IFS=,; echo "${SUBNETS[*]}")" \
      --target-group-arns "$TG_ARN" --health-check-type ELB --health-check-grace-period 900 \
      --tags "Key=Proyecto,Value=$NAME_PREFIX,PropagateAtLaunch=true"
    aws autoscaling put-scaling-policy --auto-scaling-group-name "$ASG_NAME" \
      --policy-name "${NAME_PREFIX}-cpu" --policy-type TargetTrackingScaling \
      --target-tracking-configuration "{\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"ASGAverageCPUUtilization\"},\"TargetValue\":$CPU_TARGET}" >/dev/null
    ok "$ASG_NAME creado con escalado por CPU ($CPU_TARGET%)"
  else
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" \
      --min-size "$ASG_MIN" --max-size "$ASG_MAX" --desired-capacity "$ASG_DESIRED"
    if [ "${LT_ACTUALIZADO:-0}" = 1 ]; then
      # Redeploy sin cortar el servicio: reemplaza las instancias de a una.
      aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" \
        --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":600}' >/dev/null 2>&1 \
        && ok "Instance refresh iniciado (las instancias se reemplazan con la versión nueva, de a una)" \
        || aviso "Ya había un instance refresh en curso."
    fi
  fi

  paso "Esperando que al menos una instancia esté sana en el ALB (5-12 min la primera vez)"
  local fin=$((SECONDS + 1200)) sanas=0
  while [ $SECONDS -lt $fin ]; do
    sanas=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
    [ "$sanas" -ge 1 ] 2>/dev/null && break
    printf '.'; sleep 20
  done
  echo
  if [ "$sanas" -ge 1 ] 2>/dev/null; then
    ok "$sanas instancia(s) sana(s). App disponible en: http://$(alb_dns)"
  else
    aviso "Todavía no hay instancias sanas. Revisá el log de arranque en una instancia:"
    aviso "  sudo tail -f /var/log/carta-digital-userdata.log   (o 'desplegar.sh estado' en unos minutos)"
  fi
}

# =============================================================================
# 5) CLOUDFLARE — pasos manuales (según la pizarra: se hace a mano)
# =============================================================================
cf_api() { # metodo ruta [args curl...] -> responde el JSON en stdout
  local metodo="$1" ruta="$2"; shift 2
  curl -sS -X "$metodo" "https://api.cloudflare.com/client/v4${ruta}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" "$@"
}

# Crea el KV namespace, publica el Worker (module worker) con el binding
# RATE_LIMIT_KV y activa el subdominio *.workers.dev — sin tocar el dashboard.
# Devuelve 1 (sin cortar el script) si algo falla, para que cmd_cloudflare
# caiga de nuevo a las instrucciones manuales.
cmd_cloudflare_auto() {
  local worker="$1" dns="$2"
  command -v jq >/dev/null || { aviso "Falta 'jq': no puedo automatizar Cloudflare por API."; return 1; }

  paso "Cloudflare (automático vía API) — Worker: $CF_WORKER_NAME"

  local verif
  verif=$(cf_api GET "/user/tokens/verify") || true
  echo "$verif" | jq -e '.success == true' >/dev/null 2>&1 || {
    aviso "Token de Cloudflare inválido o sin permisos: $(echo "$verif" | jq -r '.errors[0].message // "error desconocido"' 2>/dev/null)"
    return 1
  }

  local nombre_kv="${NAME_PREFIX}-rate-limit"
  local kv_id
  kv_id=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100" \
    | jq -r --arg t "$nombre_kv" '.result[]? | select(.title==$t) | .id' | head -n1)
  if [ -z "$kv_id" ]; then
    local resp_kv
    resp_kv=$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
      -H "Content-Type: application/json" --data "{\"title\":\"${nombre_kv}\"}")
    kv_id=$(echo "$resp_kv" | jq -r '.result.id // empty')
    [ -n "$kv_id" ] || { aviso "No se pudo crear el KV namespace: $(echo "$resp_kv" | jq -r '.errors[0].message // "error desconocido"')"; return 1; }
    ok "KV namespace creado: $nombre_kv"
  else
    ok "KV namespace ya existía: $nombre_kv"
  fi

  local metadata
  metadata=$(jq -n --arg kv "$kv_id" '{
    main_module: "security-proxy.js",
    compatibility_date: "2024-09-01",
    bindings: [ { type: "kv_namespace", name: "RATE_LIMIT_KV", namespace_id: $kv } ]
  }')
  local resp_worker
  resp_worker=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${CF_WORKER_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -F "metadata=${metadata};type=application/json" \
    -F "security-proxy.js=@${worker};type=application/javascript+module")
  echo "$resp_worker" | jq -e '.success == true' >/dev/null 2>&1 || {
    aviso "No se pudo publicar el Worker: $(echo "$resp_worker" | jq -r '.errors[0].message // "error desconocido"')"
    return 1
  }
  ok "Worker publicado: $CF_WORKER_NAME (origen: http://$dns)"

  # Nota: este endpoint (activar la ruta *.workers.dev de UN worker puntual)
  # rechaza la autenticación por API Token con el error 10405 "Method not
  # allowed for this authentication scheme" — es una limitación conocida de
  # Cloudflare, no un bug del script. Si falla, el Worker ya quedó publicado
  # igual; solo falta activar la ruta una vez a mano (después queda prendida
  # para siempre, no hay que repetirlo).
  local resp_subdominio
  resp_subdominio=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${CF_WORKER_NAME}/subdomain" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
    --data '{"enabled":true,"previews_enabled":false}')

  if echo "$resp_subdominio" | jq -e '.success == true' >/dev/null 2>&1; then
    ok "URL pública: https://${CF_WORKER_NAME}.${CF_SUBDOMAIN}.workers.dev"
    aviso "Puede tardar ~30-60s en quedar activo la primera vez."
  else
    aviso "No se pudo activar la ruta *.workers.dev por API: $(echo "$resp_subdominio" | jq -r '.errors[0].message // "error desconocido"')"
    aviso "Esto es normal con API Token (Cloudflare lo bloquea). Actívala una sola vez a mano:"
    aviso "  dash.cloudflare.com → Workers & Pages → $CF_WORKER_NAME → Settings → Domains & Routes → activar *.workers.dev"
    aviso "Después de activarla, la URL será: https://${CF_WORKER_NAME}.${CF_SUBDOMAIN}.workers.dev"
  fi
}

cmd_cloudflare() {
  local dns; dns=$(alb_dns)
  [ -n "$dns" ] || dns="<DNS-del-ALB>"

  # Deja el Worker listo para pegar: ORIGIN apuntando al Load Balancer.
  local worker="$RAIZ/cloudflare-worker/security-proxy.js"
  if [ -f "$worker" ] && [ "$dns" != "<DNS-del-ALB>" ]; then
    sed -i.bak -E "s#^const ORIGIN = \".*\";#const ORIGIN = \"http://$dns\";#" "$worker" && rm -f "$worker.bak"
    ok "cloudflare-worker/security-proxy.js actualizado: ORIGIN = http://$dns"
  fi

  if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ACCOUNT_ID" ] && [ -n "$CF_SUBDOMAIN" ]; then
    cmd_cloudflare_auto "$worker" "$dns" && return 0
    aviso "La automatización de Cloudflare falló; te dejo los pasos manuales como respaldo."
  fi

  cat <<TXT

${c_azul}==> Cloudflare (paso MANUAL en dash.cloudflare.com)${c_fin}

  Origen (Load Balancer de AWS):  http://$dns

  Opción A — con dominio propio${DOMINIO:+ ($DOMINIO)} → DNS + HTTPS
    1. Websites → tu dominio → DNS → Records → Add record
         Type: CNAME   Name: ${DOMINIO:-carta}   Target: $dns
         Proxy status: Proxied (nube NARANJA)   → Save
    2. SSL/TLS → Overview → modo "Flexible"
         (navegador→Cloudflare va por HTTPS; Cloudflare→ALB por HTTP:80)
    3. SSL/TLS → Edge Certificates → activar "Always Use HTTPS"
    4. Probar: https://${DOMINIO:-<tu-dominio>}/health  → {"ok":true}

  Opción B — sin dominio (Worker *.workers.dev, WAF + rate limit)
    1. Workers & Pages → tu Worker → Edit code → pegar el contenido de
       cloudflare-worker/security-proxy.js (ya quedó con el ORIGIN nuevo) → Deploy
    2. Detalle completo: cloudflare-worker/README.md

TXT
}

# =============================================================================
# ESTADO / DESTRUIR
# =============================================================================
cmd_estado() {
  paso "RDS"
  aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].{Estado:DBInstanceStatus,Endpoint:Endpoint.Address,Clase:DBInstanceClass}' \
    --output table 2>/dev/null || aviso "No existe"
  paso "Auto Scaling"
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].{Min:MinSize,Deseadas:DesiredCapacity,Max:MaxSize,Instancias:Instances[].{Id:InstanceId,Estado:LifecycleState,Salud:HealthStatus}}' \
    --output table 2>/dev/null || aviso "No existe"
  paso "Salud en el Load Balancer"
  local tg; tg=$(tg_arn)
  if [ -n "$tg" ]; then
    aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query 'TargetHealthDescriptions[].{Instancia:Target.Id,Estado:TargetHealth.State,Motivo:TargetHealth.Reason}' --output table
    echo "  URL: http://$(alb_dns)"
  else aviso "No existe"; fi
}

cmd_destruir() {
  detectar_vpc
  local mensaje_cf=""
  [ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_ACCOUNT_ID:-}" ] && mensaje_cf=" y el Worker de Cloudflare '$CF_WORKER_NAME'"
  echo "${c_rojo}Esto BORRA (sin vuelta atrás): Auto Scaling, Load Balancer, Target Group,"
  echo "Launch Template, la base RDS '$RDS_INSTANCE_ID' CON SUS DATOS, los security groups${mensaje_cf}.${c_fin}"
  read -r -p "Para confirmar escribí el prefijo ($NAME_PREFIX): " resp
  [ "$resp" = "$NAME_PREFIX" ] || error "Cancelado."

  paso "Auto Scaling Group"
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete 2>/dev/null && {
    echo "  Esperando que terminen las instancias..."
    while aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text | grep -q "$ASG_NAME"; do sleep 15; done
  } || true
  paso "Load Balancer y Target Group"
  local arn; arn=$(alb_arn)
  [ -n "$arn" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$arn" \
    && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$arn"
  arn=$(tg_arn); [ -n "$arn" ] && { sleep 10; aws elbv2 delete-target-group --target-group-arn "$arn"; }
  paso "Launch Template"
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" >/dev/null 2>&1 || true
  paso "RDS (sin snapshot final)"
  if aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null 2>&1; then
    aws rds delete-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" \
      --skip-final-snapshot --delete-automated-backups >/dev/null
    aws rds wait db-instance-deleted --db-instance-identifier "$RDS_INSTANCE_ID"
  fi
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null || true
  paso "Security groups"
  for n in "$SG_RDS" "$SG_APP" "$SG_ALB"; do
    local id; id=$(sg_id "$n")
    [ -n "$id" ] && { aws ec2 delete-security-group --group-id "$id" 2>/dev/null || aviso "No se pudo borrar $n (reintentá en unos minutos)"; }
  done

  if [ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_ACCOUNT_ID:-}" ]; then
    paso "Cloudflare — Worker '$CF_WORKER_NAME' y KV namespace"
    if command -v jq >/dev/null; then
      # cf_api usa curl -sS: el código de salida de curl indica si pudo
      # CONECTARSE, no si Cloudflare respondió éxito. Por eso se revisa
      # el campo "success" del JSON, igual que en cmd_cloudflare_auto.
      local resp_borrado
      resp_borrado=$(cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${CF_WORKER_NAME}")
      if echo "$resp_borrado" | jq -e '.success == true' >/dev/null 2>&1; then
        ok "Worker borrado: $CF_WORKER_NAME"
      else
        aviso "Worker '$CF_WORKER_NAME' no se pudo borrar: $(echo "$resp_borrado" | jq -r '.errors[0].message // "ya no existía o error desconocido"')"
      fi
      local nombre_kv kv_id
      nombre_kv="${NAME_PREFIX}-rate-limit"
      kv_id=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100" \
        | jq -r --arg t "$nombre_kv" '.result[]? | select(.title==$t) | .id' | head -n1)
      if [ -n "$kv_id" ]; then
        local resp_kv_borrado
        resp_kv_borrado=$(cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${kv_id}")
        if echo "$resp_kv_borrado" | jq -e '.success == true' >/dev/null 2>&1; then
          ok "KV namespace borrado: $nombre_kv"
        else
          aviso "No se pudo borrar el KV namespace '$nombre_kv': $(echo "$resp_kv_borrado" | jq -r '.errors[0].message // "error desconocido"')"
        fi
      fi
    else
      aviso "Falta 'jq': no puedo borrar el Worker/KV de Cloudflare por API. Bórralos a mano en dash.cloudflare.com."
    fi
  fi

  ok "Listo."
}

# =============================================================================
main() {
  local cmd="${1:-todo}"
  cd "$RAIZ"
  cargar_config
  case "$cmd" in
    verificar)  cmd_verificar ;;
    docker)     cmd_docker ;;
    red)        cmd_red ;;
    base-datos) cmd_base_datos ;;
    app)        cmd_app ;;
    cloudflare) cmd_cloudflare ;;
    estado)     cmd_estado ;;
    destruir)   cmd_destruir ;;
    todo)
      cmd_verificar
      [ "${SALTAR_DOCKER:-0}" = 1 ] || cmd_docker
      cmd_red
      cmd_base_datos
      cmd_app
      cmd_cloudflare
      ;;
    *) sed -n '2,32p' "$0"; exit 1 ;;
  esac
}
main "$@"
