# Despliegue automático — Docker + AWS + Cloudflare

Un solo script, `scripts/deploy/desplegar.sh`, levanta todo lo que pide la entrega:

```
Git (rama nueva) ─► Docker ─► AWS ─┬─ RDS (PostgreSQL)
                                   ├─ Application Load Balancer
                                   └─ Auto Scaling Group (EC2 con la app en Docker)
Cloudflare (DNS + HTTPS) ◄──────── paso MANUAL (el script imprime los datos exactos)
```

| Paso | Qué hace | Automático |
|---|---|---|
| `verificar` | Revisa AWS CLI, que tengas sesión iniciada en AWS, las variables y que la rama exista en GitHub | ✅ |
| `docker` | `docker build` + prueba el contenedor con un Postgres temporal (`/health`, `/api/restaurantes`) | ✅ |
| `red` | Security groups: ALB (80/443 público) → app (80 solo desde el ALB) → RDS (5432 solo desde la app) | ✅ |
| `base-datos` | Crea la RDS PostgreSQL (privada, backups 7 días) | ✅ |
| `app` | Target Group, Load Balancer, Launch Template, Auto Scaling (escala por CPU) | ✅ |
| (en cada EC2) | Instala Docker, clona la rama, crea el usuario/la base en RDS, carga `db/init.sql` **solo si la base está vacía** y levanta `app-prod` | ✅ |
| `cloudflare` | Apunta el Worker al Load Balancer e imprime los pasos de DNS/HTTPS | ⚠️ manual |

## 1. Credenciales: ¿hay que iniciar sesión?

**Sí, en dos lugares, y ninguno va dentro del script:**

**AWS** — el script usa la sesión de la AWS CLI que ya tengas. Elegí una:

- **AWS CloudShell (recomendado):** entrás a la consola de AWS → ícono `>_` arriba a la derecha. Ya tiene la sesión iniciada; no hay que configurar nada.
- **Tu PC (WSL o Git Bash):** `aws configure` y pegás *Access Key ID* + *Secret Access Key* (IAM → tu usuario → *Security credentials*). En **AWS Academy / Learner Lab** las credenciales son temporales: copialas de *AWS Details → AWS CLI* (incluyen `aws_session_token`) en `~/.aws/credentials`, y se renuevan en cada sesión del lab.

Comprobación rápida: `aws sts get-caller-identity` (el script lo hace solo en `verificar`).

**Cloudflare** — iniciás sesión en <https://dash.cloudflare.com> con tu cuenta y hacés el paso final a mano (el script te imprime qué poner).

**Contraseñas de la app** — van en `scripts/deploy/deploy.env` (copia de `deploy.env.example`, está en `.gitignore`):

| Variable | Qué es |
|---|---|
| `GITHUB_BRANCH` | La rama nueva que subiste (las EC2 clonan esa rama) |
| `GITHUB_TOKEN` | Token de GitHub **solo lectura** del repo (necesario porque el repo es privado): *Settings → Developer settings → Fine-grained tokens*, repo `carta-digital`, permiso *Contents: Read-only* |
| `RDS_MASTER_PASSWORD` | Contraseña del usuario administrador de RDS (la inventás vos) |
| `DB_PASSWORD` | Contraseña del usuario `carta_app` que usa la app (la inventás vos) |
| `SESSION_SECRET` | Secreto de las cookies de sesión: `openssl rand -hex 32` |
| `KEY_NAME` | (Opcional) key pair para entrar por SSH; en AWS Academy suele ser `vockey` |

## 2. Paso a paso

```bash
# 1) Clonar el repo (la rama entrega-final ya existe en GitHub)
git clone https://github.com/Cira-yt/carta-digital.git && cd carta-digital
git checkout entrega-final        # la rama que despliega el script

# 2) Configuración
cp scripts/deploy/deploy.env.example scripts/deploy/deploy.env
nano scripts/deploy/deploy.env        # completar los <-- COMPLETAR

# 3) Desplegar todo (15-25 min la primera vez; casi todo es esperar a RDS)
bash scripts/deploy/desplegar.sh
#    sin Docker en la máquina (ej. CloudShell con poco disco):
SALTAR_DOCKER=1 bash scripts/deploy/desplegar.sh

# 4) Ver cómo va
bash scripts/deploy/desplegar.sh estado
```

Al final imprime la URL `http://<alb>.elb.amazonaws.com` y los pasos de Cloudflare.

**Volver a desplegar** (después de otro `git push` a la rama): `bash scripts/deploy/desplegar.sh app` — crea una versión nueva del Launch Template y reemplaza las instancias de a una (*instance refresh*), sin cortar el servicio.

**Apagar todo** para no gastar créditos: `bash scripts/deploy/desplegar.sh destruir` (pide escribir el prefijo para confirmar; borra también la base RDS).

## 3. Cloudflare (manual)

Con dominio propio (DNS + HTTPS):

1. *DNS → Records → Add record*: `CNAME` · nombre `carta` (o `@`) · destino = DNS del ALB · **Proxied** (nube naranja).
2. *SSL/TLS → Overview*: modo **Flexible** (navegador→Cloudflare HTTPS; Cloudflare→ALB HTTP).
3. *SSL/TLS → Edge Certificates*: activar **Always Use HTTPS**.
4. Probar `https://<tu-dominio>/health` → `{"ok":true}`.

Sin dominio: usar el Worker de `cloudflare-worker/` (el script ya dejó `ORIGIN` apuntando al ALB en `security-proxy.js`; solo hay que pegarlo en el dashboard — ver `cloudflare-worker/README.md`).

## 4. Problemas comunes

- **"No hay credenciales de AWS válidas"**: sesión de AWS Academy vencida → volver a copiar las credenciales, o usar CloudShell.
- **Instancias `unhealthy` en el ALB**: entrar por SSH a una y ver `sudo tail -f /var/log/carta-digital-userdata.log`. Lo más común: falta o venció `GITHUB_TOKEN`, la rama no tiene el código más reciente, o una contraseña con caracteres raros (usá solo letras y números).
- **AWS Academy no deja crear algo** (ej. `UnauthorizedOperation`): algunos labs limitan tipos de instancia o regiones; usá `us-east-1` y `t3.micro`/`db.t3.micro`.

> Nota de seguridad: las contraseñas viajan en el *user-data* del Launch Template (visible para quien tenga acceso a EC2 en la cuenta). Para un proyecto de curso es aceptable; en producción real se guardarían en AWS Secrets Manager / SSM Parameter Store.
