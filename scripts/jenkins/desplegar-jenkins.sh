#!/usr/bin/env bash
# =============================================================================
# Carta Digital — despliega Jenkins en una EC2 propia (Docker), separada de
# las instancias de la app.
#
# Jenkins acá es solo un VERIFICADOR de Pull Requests (build, tests,
# gitleaks, npm audit), no un desplegador automático — ver Jenkinsfile y
# docs/jenkins.md para el porqué y la configuración completa del Job.
#
# Por diseño, Jenkins NO se expone a internet: el Job usa polling (revisa
# GitHub cada pocos minutos), no un webhook público. El panel (puerto 8080)
# solo es accesible desde tu propia IP (MI_IP en jenkins.env), igual que
# restringimos el ALB de la app a las IPs de Cloudflare.
#
# Uso (desde la raíz del repo, en AWS CloudShell):
#
#   cp scripts/jenkins/jenkins.env.example scripts/jenkins/jenkins.env   # y completarlo
#   bash scripts/jenkins/desplegar-jenkins.sh            # = "todo"
#
# Subcomandos:
#   verificar   herramientas, credenciales de AWS y variables
#   red         security group (8080 y 22 solo desde MI_IP)
#   jenkins     crea la instancia EC2 e instala Jenkins (Docker)
#   password    muestra la contraseña inicial de administrador de Jenkins
#   estado      IP pública y estado de la instancia
#   todo        verificar → red → jenkins → password
#   destruir    BORRA la instancia y el security group (pide confirmación).
#               Esto borra también la configuración de Jenkins (jobs,
#               credenciales) salvo que hayas hecho un backup aparte.
# =============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR_JENKINS="$RAIZ/scripts/jenkins"
CONFIG="${CONFIG:-$DIR_JENKINS/jenkins.env}"

c_azul=$'\e[1;34m'; c_verde=$'\e[1;32m'; c_amarillo=$'\e[1;33m'; c_rojo=$'\e[1;31m'; c_fin=$'\e[0m'
paso()  { echo; echo "${c_azul}==> $*${c_fin}"; }
ok()    { echo "${c_verde}  ✔ $*${c_fin}"; }
aviso() { echo "${c_amarillo}  ! $*${c_fin}"; }
error() { echo "${c_rojo}  ✘ $*${c_fin}" >&2; exit 1; }

limpio() { local v; v="$(cat)"; [ "$v" = "None" ] && v=""; printf '%s' "$v"; }

cargar_config() {
  [ -f "$CONFIG" ] || error "No existe $CONFIG. Copiá la plantilla: cp scripts/jenkins/jenkins.env.example scripts/jenkins/jenkins.env"
  # shellcheck disable=SC1090
  set -a; source <(sed 's/\r$//' "$CONFIG"); set +a

  AWS_REGION="${AWS_REGION:-us-east-1}"
  NAME_PREFIX="${NAME_PREFIX:-carta-jenkins}"
  INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
  KEY_NAME="${KEY_NAME:-}"
  MI_IP="${MI_IP:-}"
  SG_NAME="${NAME_PREFIX}-sg"
  INSTANCE_NAME="${NAME_PREFIX}-ec2"

  [ -n "$MI_IP" ] || error "Definí MI_IP en $CONFIG (tu IP pública + /32). Sin esto Jenkins quedaría abierto a cualquiera o inaccesible."
}

cmd_verificar() {
  paso "Verificando herramientas"
  command -v aws >/dev/null || error "Falta aws-cli."
  ok "aws $(aws --version 2>&1 | cut -d' ' -f1)"

  paso "Verificando credenciales de AWS"
  local id; id=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
    || error "No hay sesión de AWS activa. En CloudShell basta con estar logueado; si no, corré 'aws configure'."
  ok "Identidad: $id (región $AWS_REGION)"

  paso "Verificando variables de $CONFIG"
  ok "MI_IP=$MI_IP, INSTANCE_TYPE=$INSTANCE_TYPE"
}

detectar_vpc() {
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text | limpio)
  [ -n "$VPC_ID" ] || error "La cuenta no tiene VPC por defecto: usá CONFIG con VPC_ID."
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' --output text | limpio)
  [ -n "$SUBNET_ID" ] || error "No encontré una subnet por defecto en $VPC_ID."
}

sg_id() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | limpio
}

abrir_puerto() { # sg puerto cidr
  local sg="$1" puerto="$2" cidr="$3" salida
  if ! salida=$(aws ec2 authorize-security-group-ingress --group-id "$sg" \
    --protocol tcp --port "$puerto" --cidr "$cidr" 2>&1); then
    echo "$salida" | grep -q "InvalidPermission.Duplicate" || { echo "$salida" >&2; exit 1; }
  fi
}

cmd_red() {
  detectar_vpc
  paso "Security group ($SG_NAME) — 8080 y 22 solo desde $MI_IP"
  local sg; sg=$(sg_id "$SG_NAME")
  if [ -z "$sg" ]; then
    sg=$(aws ec2 create-security-group --group-name "$SG_NAME" \
      --description "Jenkins - Carta Digital (solo verificador de PRs)" \
      --vpc-id "$VPC_ID" --query GroupId --output text)
    aws ec2 create-tags --resources "$sg" --tags "Key=Name,Value=$SG_NAME" "Key=Proyecto,Value=$NAME_PREFIX"
  fi
  abrir_puerto "$sg" 8080 "$MI_IP"
  [ -z "$KEY_NAME" ] || abrir_puerto "$sg" 22 "$MI_IP"
  SG_ID="$sg"
  ok "$SG_ID"
}

instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null | limpio
}

generar_user_data() { # archivo destino
  cat > "$1" <<'CUERPO'
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/jenkins-userdata.log) 2>&1

echo "== [1/3] Docker =="
dnf install -y docker
systemctl enable --now docker

echo "== [2/3] Imagen de Jenkins con docker CLI (para que los pipelines puedan levantar contenedores) =="
mkdir -p /opt/jenkins-imagen
cat > /opt/jenkins-imagen/Dockerfile <<'DOCKERFILE'
FROM jenkins/jenkins:lts
USER root
RUN apt-get update && apt-get install -y --no-install-recommends docker.io docker-cli && rm -rf /var/lib/apt/lists/*
RUN docker --version
USER jenkins
DOCKERFILE
docker build -t jenkins-con-docker /opt/jenkins-imagen

echo "== [3/3] Contenedor de Jenkins (puerto 8080, con socket de Docker montado) =="
docker volume create jenkins_home >/dev/null
docker run -d --name jenkins --restart unless-stopped \
  -p 8080:8080 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" \
  jenkins-con-docker

echo "== Esperando la contraseña inicial de administrador =="
for i in $(seq 1 60); do
  if docker exec jenkins test -f /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null; then
    echo "CONTRASEÑA_INICIAL_JENKINS: $(docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword)"
    break
  fi
  sleep 5
done
CUERPO
}

cmd_jenkins() {
  [ -n "${SG_ID:-}" ] || cmd_red
  paso "Instancia EC2 de Jenkins"
  local id; id=$(instance_id)
  if [ -n "$id" ]; then
    ok "Ya existe: $id (se reutiliza)"
  else
    local ami; ami=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text | limpio)
    local ud; ud=$(mktemp); generar_user_data "$ud"
    id=$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
      --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
      ${KEY_NAME:+--key-name "$KEY_NAME"} \
      --user-data "file://$ud" \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Proyecto,Value=$NAME_PREFIX}]" \
      --query 'Instances[0].InstanceId' --output text)
    rm -f "$ud"
    ok "Instancia creada: $id"
    echo "  Esperando a que arranque (2-4 min)..."
    aws ec2 wait instance-running --instance-ids "$id"
  fi
  INSTANCE_ID="$id"
  local ip; ip=$(aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text | limpio)
  ok "Jenkins va a estar en http://$ip:8080 (puede tardar 1-2 min más en instalar Docker y levantar el contenedor)"
}

cmd_password() {
  local id; id=$(instance_id)
  [ -n "$id" ] || error "No encontré la instancia de Jenkins. Corré primero: desplegar-jenkins.sh jenkins"
  paso "Buscando la contraseña inicial en la consola de la instancia (puede tardar unos minutos en aparecer)"
  for i in $(seq 1 30); do
    local salida
    salida=$(aws ec2 get-console-output --instance-id "$id" --output text 2>/dev/null | grep "CONTRASEÑA_INICIAL_JENKINS" || true)
    if [ -n "$salida" ]; then ok "$salida"; return 0; fi
    sleep 10
  done
  aviso "Todavía no aparece en la consola. Alternativa manual (con EC2 Instance Connect o SSH, si configuraste KEY_NAME):"
  aviso "  sudo docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
}

cmd_estado() {
  local id; id=$(instance_id)
  [ -n "$id" ] || { aviso "No hay instancia de Jenkins creada."; return 0; }
  aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].{Estado:State.Name,IP:PublicIpAddress}' --output table
}

cmd_destruir() {
  detectar_vpc
  echo "${c_rojo}Esto BORRA la instancia de Jenkins '$INSTANCE_NAME' y su security group."
  echo "La configuración de Jenkins (jobs, credenciales) se pierde salvo que hayas hecho un backup.${c_fin}"
  read -r -p "Para confirmar escribí el prefijo ($NAME_PREFIX): " resp
  [ "$resp" = "$NAME_PREFIX" ] || error "Cancelado."

  local id; id=$(instance_id)
  if [ -n "$id" ]; then
    paso "Terminando la instancia"
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$id"
  fi
  paso "Security group"
  local sg; sg=$(sg_id "$SG_NAME")
  [ -z "$sg" ] || aws ec2 delete-security-group --group-id "$sg" 2>/dev/null \
    || aviso "No se pudo borrar $SG_NAME todavía (reintentá en unos minutos)."
  ok "Listo."
}

main() {
  local cmd="${1:-todo}"
  cd "$RAIZ"
  cargar_config
  case "$cmd" in
    verificar) cmd_verificar ;;
    red)       cmd_red ;;
    jenkins)   cmd_jenkins ;;
    password)  cmd_password ;;
    estado)    cmd_estado ;;
    destruir)  cmd_destruir ;;
    todo)
      cmd_verificar
      cmd_red
      cmd_jenkins
      cmd_password
      ;;
    *) error "Comando desconocido: $cmd" ;;
  esac
}

main "$@"
