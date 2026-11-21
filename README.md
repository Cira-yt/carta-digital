# 🍽️ Carta Digital — pnkSecurity

Carta digital para restaurantes: el cliente **escanea el QR de su mesa**, ve el menú con fotos y precios, arma su pedido y lo confirma desde el celular. Cada restaurante tiene un **panel de administración** para gestionar cartas, categorías, productos, pedidos y seguridad (2FA).

Proyecto construido con **seguridad desde el diseño**: incorpora las correcciones del informe de remediación `pnkSecurity` (OWASP Top 10) y se despliega en AWS detrás de Cloudflare.

![Node.js](https://img.shields.io/badge/Node.js-20-339933?logo=node.js&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-5-3178C6?logo=typescript&logoColor=white)
![React](https://img.shields.io/badge/React-18-61DAFB?logo=react&logoColor=black)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-✔-2496ED?logo=docker&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-RDS%20·%20ALB%20·%20ASG-FF9900?logo=amazonaws&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-DNS%20·%20WAF-F38020?logo=cloudflare&logoColor=white)

---

## Índice

1. [Stack](#stack)
2. [Arquitectura](#arquitectura)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Puesta en marcha local](#puesta-en-marcha-local)
5. [Docker: 3 ambientes](#docker-3-ambientes)
6. [Despliegue automático (AWS + Cloudflare)](#despliegue-automático-aws--cloudflare)
7. [CI/CD](#cicd)
8. [Pruebas](#pruebas)
9. [Seguridad implementada](#seguridad-implementada)
10. [API](#api)
11. [Documentación](#documentación)

---

## Stack

| Capa | Tecnología |
|---|---|
| Frontend público | **React 18 + TypeScript** (Vite, React Router). Tipografías autoalojadas: *Fraunces* + *Plus Jakarta Sans* |
| Panel admin | Express + vistas **EJS** (autoescapadas) + TypeScript del cliente |
| Backend | **Node.js 20 + Express + TypeScript**, arquitectura **MVC** |
| Base de datos | **PostgreSQL 17** (local/Docker en dev y QA, **AWS RDS** en producción) |
| Sesiones | `express-session` respaldadas en PostgreSQL (`connect-pg-simple`) |
| Contenedores | Dockerfile multi-etapa (usuario no-root + healthcheck) y `docker-compose` con 3 ambientes |
| Nube | AWS: **RDS**, **Application Load Balancer**, **Auto Scaling Group** (EC2) |
| Borde | **Cloudflare**: DNS + HTTPS y Worker con WAF ligero y rate limiting |
| CI/CD | GitHub Actions (3 ambientes) + Jenkins (verificador de Pull Requests: tests, gitleaks, `npm audit`) |
| Pruebas | Jest + Supertest |

## Arquitectura

```
                 HTTPS                        HTTP
 Cliente ──────────────► Cloudflare ──────────────────► Application Load Balancer (2 zonas)
 (QR de la mesa)         DNS + WAF                                │
                         rate limiting                ┌───────────┴───────────┐
                                                      ▼                       ▼
                                               EC2 (Auto Scaling)     EC2 (Auto Scaling)
                                               Docker: app-prod       Docker: app-prod
                                                      │                       │
                                                      └──────────┬────────────┘
                                                                 ▼  (red privada, SSL)
                                                       AWS RDS · PostgreSQL 17
```

Dentro de cada contenedor, Express sirve:

- `/` y `/:slug` → SPA de React (el QR apunta a `/<slug-del-restaurante>`)
- `/api/*` → API JSON que consume la SPA
- `/admin/*` → panel de administración (EJS)
- `/health` → chequeo de salud para Docker y el Load Balancer

## Estructura del repositorio

```
.
├── frontend/                  ← SPA pública en React (Vite)
│   └── src/
│       ├── pages/             ← Bienvenida, Carta, Carrito, NoEncontrado
│       ├── components/        ← Header, Layout, LoginModal
│       ├── context/           ← sesión, carrito, toasts
│       ├── styles/global.css  ← diseño del sitio público
│       └── api.ts             ← cliente de la API (CSRF por header)
├── src/                       ← backend (MVC)
│   ├── app.ts · server.ts     ← ensamblado y arranque
│   ├── config/                ← variables de entorno, pool de PostgreSQL
│   ├── middlewares/           ← sesión, CSRF, helmet, rate limit, subida de archivos, errores
│   ├── models/                ← acceso a datos (consultas parametrizadas)
│   ├── controllers/           ← lógica de cada ruta
│   ├── routes/                ← /api (público) y /admin
│   ├── views/admin/           ← plantillas EJS del panel
│   ├── public/                ← estáticos: css, imágenes, vendors, TS del panel
│   └── scripts/               ← seed y migración de datos desde MySQL
├── db/
│   ├── init.sql               ← esquema + datos iniciales (se carga solo en Docker/RDS)
│   ├── schema.sql             ← esquema limpio (usado por las pruebas)
│   └── migraciones/
├── tests/                     ← pruebas funcionales (Jest + Supertest)
├── scripts/
│   ├── deploy/                ← ⭐ despliegue automático (Docker + AWS)
│   │   ├── desplegar.sh
│   │   ├── deploy.env.example
│   │   └── sql/               ← inicialización idempotente de RDS
│   ├── jenkins/                ← ⭐ despliega Jenkins (verificador de PRs), ver docs/jenkins.md
│   └── aws/                   ← scripts operativos (runbook, migración a RDS, ALB/ASG)
├── cloudflare-worker/         ← Worker de seguridad (WAF + rate limit + anti-scanners)
├── docs/                      ← guías: despliegue, infraestructura, Jenkins
├── .github/workflows/         ← GitHub Actions (dev / QA / prod)
├── Dockerfile · docker-compose.yml · Jenkinsfile
└── package.json
```

## Puesta en marcha local

Requisitos: **Node.js 18+** y un **PostgreSQL 15+** (local o Docker).

```bash
npm install
cp .env.example .env              # completar PGPASSWORD y SESSION_SECRET

# Cargar el esquema y los datos de ejemplo (define las contraseñas de los
# usuarios de prueba admin@gmail.com / alondra@gmail.com que crea el seed;
# usá las que quieras, son solo para tu base local)
ADMIN_SEED_PASSWORD=cambia-esta-clave CLIENTE_SEED_PASSWORD=cambia-esta-clave \
  psql -h 127.0.0.1 -U carta_app -d carta_digital -f db/init.sql

npm run dev                       # backend en http://localhost:3000
npm run dev:frontend              # (opcional) React con recarga en http://localhost:5173
```

Build de producción:

```bash
npm run build                     # backend → dist/, panel → dist/public, React → dist/public-spa
npm start                         # node dist/server.js
```

## Docker: 3 ambientes

`docker-compose.yml` define **Desarrollo**, **QA** y **Producción**, aislados entre sí (cada uno con su red, volúmenes y `.env`).

```bash
cp .env.docker.example .env.dev    # y lo mismo para .env.qa / .env.prod

docker compose up -d --build app-dev db-dev    # http://localhost:3001
docker compose up -d --build app-qa  db-qa     # http://localhost:3002
docker compose up -d --build app-prod          # usa la BD de producción (RDS)
```

## Despliegue automático (AWS + Cloudflare)

Un solo script crea toda la infraestructura. Es **idempotente**: si un recurso ya existe, lo reutiliza.

```bash
cp scripts/deploy/deploy.env.example scripts/deploy/deploy.env   # completar contraseñas y rama
bash scripts/deploy/desplegar.sh            # verificar → docker → red → RDS → ALB + ASG → Cloudflare
```

| Comando | Qué hace |
|---|---|
| `verificar` | Herramientas, sesión de AWS, variables y rama de Git |
| `docker` | Construye la imagen y la prueba con un Postgres temporal |
| `red` / `base-datos` / `app` | Security groups · RDS · Load Balancer + Auto Scaling |
| `cloudflare` | Automatiza Cloudflare por API (Worker + KV + subdominio) si `CF_API_TOKEN`/`CF_ACCOUNT_ID`/`CF_SUBDOMAIN` están completos en `deploy.env`; si no, imprime los pasos manuales de DNS/HTTPS |
| `estado` | Estado de RDS, Auto Scaling y salud en el Load Balancer |
| `destruir` | Borra Auto Scaling, Load Balancer, security groups y Cloudflare — **no** toca la RDS (pide confirmación) |
| `destruir-todo` | Lo mismo que `destruir`, y además borra la RDS con sus datos (irreversible, confirmación más exigente) |

> **Credenciales:** el script usa la sesión de la AWS CLI (**AWS CloudShell** o `aws configure`). Las contraseñas de la app van en `scripts/deploy/deploy.env`, que **no se sube al repo**. Cloudflare se configura solo (sin dominio propio) con `CF_API_TOKEN`/`CF_ACCOUNT_ID`/`CF_SUBDOMAIN`, o a mano en el dashboard si preferís dominio propio.
> Guía completa: [`docs/despliegue-automatico.md`](docs/despliegue-automatico.md).

## CI/CD

- **GitHub Actions** (`.github/workflows/ambientes.yml`), en cada push:
  - Levanta el ambiente de **Desarrollo**.
  - Levanta el ambiente de **QA** y corre la suite de pruebas.
  - Valida que la imagen de **Producción** compile.
- **Jenkins** (`Jenkinsfile`): verifica cada Pull Request hacia `main` — build, tests, `gitleaks` (secretos filtrados) y `npm audit` — y publica el resultado como check del PR. No despliega nada: el merge requiere además al menos 1 aprobación humana (branch protection). Guía completa: [`docs/jenkins.md`](docs/jenkins.md).

## Pruebas

```bash
npm test
```

Usan **Jest + Supertest** contra la app real (`createApp()`) y una base de datos de pruebas. Cubren:

- **API pública**: restaurantes, carta por slug y `/health`.
- **Autenticación y acceso**: login, CSRF y acceso al panel admin.
- **Pedidos**: carrito y checkout, incluido un carrito con productos de varios restaurantes.
- **Panel admin y ventas**: con prueba de IDOR (no se puede cambiar el pedido de otro restaurante).
- **Rate limiting** del login.

Detalle: [`tests/README.md`](tests/README.md).

## Seguridad implementada

| Riesgo | Mitigación |
|---|---|
| Inyección SQL | Consultas 100 % parametrizadas (`$1, $2…` con `pg`) |
| Contraseñas | Hash **bcrypt** (costo 12) |
| XSS | React y EJS escapan por defecto; CSP estricta con `helmet` |
| CSRF | Token por sesión, validado en cada POST (header `X-CSRF-Token` en la SPA) |
| Sesión | Cookie `HttpOnly` + `SameSite=Strict` (+ `Secure` con HTTPS), guardada en PostgreSQL |
| Fuerza bruta | `express-rate-limit` en `/login` (5 intentos / 15 min) + rate limit en Cloudflare |
| Autenticación | **2FA (TOTP)** opcional para administradores |
| Control de acceso / IDOR | Autor tomado de la sesión; cada admin solo opera sobre su restaurante |
| Enumeración | Restaurantes por **slug**, no por id secuencial |
| Errores | Sin stack traces ni SQL hacia el cliente |
| Contenedor | Usuario no-root, imagen mínima (alpine), healthcheck |
| Infraestructura | RDS privada (solo accesible desde la app), ALB como única entrada pública, WAF en el borde |
| Dependencias | `npm audit` + `gitleaks` en cada Pull Request (Jenkins) |

Más detalle: [`docs/OWASP.md`](docs/OWASP.md).

## API

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/csrf` | Token CSRF de la sesión |
| GET | `/api/sesion` | Usuario actual |
| GET | `/api/restaurantes` | Listado de restaurantes |
| GET | `/api/restaurantes/:slug` | Carta completa (destacados, secciones, comentarios) |
| POST | `/api/login` · `/api/login/2fa` · `/api/logout` | Autenticación |
| GET | `/api/carrito` | Ver carrito |
| POST | `/api/carrito/agregar` · `eliminar` · `vaciar` · `confirmar` | Gestión del pedido |
| POST | `/api/comentarios` | Comentar (requiere sesión) |
| GET | `/health` | Salud del servicio |

El panel `/admin` incluye dashboard, cartas/categorías/productos, restaurantes, ventas, 2FA y un resumen OWASP.

## Documentación

- [`docs/despliegue-automatico.md`](docs/despliegue-automatico.md): despliegue y credenciales.
- [`docs/infraestructura-load-balancer-auto-scaling.md`](docs/infraestructura-load-balancer-auto-scaling.md): detalle del ALB y el Auto Scaling.
- [`docs/jenkins.md`](docs/jenkins.md): verificador de Pull Requests (Jenkins) y branch protection.
- [`docs/OWASP.md`](docs/OWASP.md): mapeo de vulnerabilidades y su remediación.
- [`cloudflare-worker/README.md`](cloudflare-worker/README.md): capa de seguridad en Cloudflare.
- [`tests/README.md`](tests/README.md): pruebas funcionales.


## Prueba de jenkins
 21/11/2026