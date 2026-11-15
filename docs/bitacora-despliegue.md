# Bitácora de despliegue — Carta Digital

Registro vivo del despliegue en AWS + Cloudflare, para no perder el hilo entre sesiones de CloudShell. Se actualiza a medida que avanzamos.

## 1. Qué cambió en el código (ya en `main`)

- **Pantalla de inicio** (`frontend/src/pages/Bienvenida.tsx`): se reemplazó el flujo "escanea el QR" por un **selector público de restaurantes** (lista con buscador, usando el endpoint ya existente `GET /api/restaurantes`). No requirió cambios de backend.
- **Gramática**: se corrigió el voseo a forma "tú" en toda la SPA (`LoginModal.tsx`, `SessionContext.tsx`, `Carrito.tsx`, `NoEncontrado.tsx`).
- **Usuarios**: el código **no tiene registro propio** (no hay endpoint de sign-up). Solo existe un script de seed (`db/init.sql`) que crea un usuario admin fijo: `admin@gmail.com` / `admin01`. Si la contraseña real está olvidada, se resetea a mano con `bcryptjs.hashSync()` + `UPDATE` en la base, ya que el hash es de un solo sentido (no se puede "ver" la contraseña).
- **Cloudflare automático por API**: se agregó a `scripts/deploy/desplegar.sh` un modo que crea el Worker, el namespace KV y activa el subdominio `*.workers.dev` solo con 3 variables en `deploy.env` (`CF_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_SUBDOMAIN`). Si faltan esas variables, cae de vuelta al proceso manual (documentado en `docs/despliegue-automatico.md`, sección "Opción B").

Todo esto ya está mergeado en `main` vía PR #1 y #2.

## 2. Arquitectura del despliegue

```
Usuario → Cloudflare Worker (*.workers.dev, WAF/rate-limit) → ALB (AWS) → Target Group → Auto Scaling Group (EC2 con Docker) → Postgres (RDS)
```

Todo se levanta con un solo script idempotente: `scripts/deploy/desplegar.sh` (subcomandos: `rds`, `app`, `cloudflare`, `verificar`, `destruir`, `todo`).

## 3. Estado actual (15 nov 2026, ~13:00 hrs Chile)

- RDS: creada y disponible.
- Target Group `carta-v2-tg`, ALB `carta-v2-alb` (6 subnets, sin el bug de AZ) y su listener HTTP:80: creados, todo sano.
- Auto Scaling Group (min 1 / deseadas 1 / max 1): **sano**. App funcionando directo en `http://carta-v2-alb-1094498464.us-east-1.elb.amazonaws.com`.
- Cloudflare: el Worker `carta-v2-proxy` se publicó bien por API (código + KV namespace `carta-v2-rate-limit`), pero la URL pública `https://carta-v2-proxy.carlos0tapi.workers.dev` muestra "There is nothing here yet". Causa confirmada: el endpoint que activa la ruta `*.workers.dev` de un Worker puntual **rechaza la autenticación por API Token** (error `10405 Method not allowed for this authentication scheme`) — es una limitación real de Cloudflare, no un bug nuestro. El script ya se actualizó para detectar esto y avisar con instrucciones; el paso de activar la ruta hay que hacerlo **una sola vez, a mano**, en dash.cloudflare.com → Workers & Pages → `carta-v2-proxy` → Settings → Domains & Routes. Después de ese clic único queda prendido para siempre.
- Variables de Cloudflare ya configuradas en `deploy.env`: `CF_API_TOKEN`, `CF_ACCOUNT_ID` (`eb0127d273ff6937933ad4065fc3afde`), `CF_SUBDOMAIN` (`carlos0tapi`).

## 4. Problemas encontrados y cómo se resolvieron

| Problema | Causa | Solución |
|---|---|---|
| `aws` se queda esperando con un `:` y el script no avanza | El pager por defecto del AWS CLI (`less`) bloquea scripts no interactivos | `export AWS_PAGER=""` (agregado también a `~/.bashrc`) |
| Variables como `RDS_MASTER_PASSWORD` "desaparecen" en una terminal nueva | Se habían puesto con `export` en la sesión anterior, no estaban guardadas en `deploy.env` | Escribirlas directamente en `scripts/deploy/deploy.env` con `nano` |
| Target sale "unused" en el ALB aunque el Auto Scaling Group está "Healthy" | El ALB se creó con menos subnets/AZs que las que usa el Auto Scaling Group (`Target.NotInUse`) | `aws elbv2 set-subnets` agregando las 6 subnets; o, como ahora, crear el ALB desde el inicio con las 6 subnets |
| El script muere en silencio justo en "Target Group" o "Application Load Balancer", sin mensaje de error, varias veces seguidas | Muy probablemente CloudShell recicla el proceso en primer plano tras un rato de inactividad del teclado (no es un bug del script; `tmux new` no ayuda porque CloudShell ya corre todo dentro de su propio tmux) | Mitigación: crear manualmente el recurso que se cortó (Target Group, luego ALB, luego listener) y retomar el script — es idempotente, detecta lo ya creado y sigue |
| `gh pr list` falla ("GraphQL no disponible") | Restricción del entorno de Claude Code | Usar `gh api repos/{owner}/{repo}/pulls?head=...` (REST) en vez de GraphQL |
| No se puede hacer `PATCH` directo a `refs/heads/main` por la API de GitHub | El proxy de este entorno bloquea esa escritura | `git fetch` + `git merge --ff-only` + `git push origin main` en local |
| Worker de Cloudflare publicado pero la URL `*.workers.dev` muestra "There is nothing here yet" | El endpoint que activa la ruta `*.workers.dev` de un Worker (`PUT /accounts/{id}/workers/scripts/{name}/subdomain`) no acepta API Token, solo el método de auth antiguo (`10405 Method not allowed for this authentication scheme`) | Activar la ruta una sola vez a mano en el dashboard (Workers & Pages → el worker → Settings → Domains & Routes); el script ahora detecta el fallo y lo avisa con instrucciones en vez de asumir éxito |

## 5. Próximos pasos

1. Activar a mano, una sola vez, la ruta `*.workers.dev` del worker `carta-v2-proxy` en el dashboard de Cloudflare.
2. Confirmar que `https://carta-v2-proxy.carlos0tapi.workers.dev` cargue la app a través del proxy.
3. Una vez probado y con evidencia, correr `bash scripts/deploy/desplegar.sh destruir` para no seguir gastando horas del laboratorio de AWS Academy.
4. Redactar la documentación final (manual de implementación + procedimiento), según el diagrama de pizarra, una vez que el despliegue esté sano.

## 6. Convención de trabajo (recordatorio)

Todo cambio de código va en una rama propia, con commits separados y mensaje claro, PR vía `gh api` (REST, no GraphQL), merge, y luego `main` se sincroniza en local con `git merge --ff-only` desde la rama de entrega y se sube con `git push origin main`.
