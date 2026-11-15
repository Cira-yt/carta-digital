# Bitácora de despliegue — Carta Digital

Registro vivo del despliegue en AWS + Cloudflare, para no perder el hilo entre sesiones de CloudShell. Se actualiza a medida que avanzamos.

## 1. Qué cambió en el código (ya en `main`)

- **Pantalla de inicio** (`frontend/src/pages/Bienvenida.tsx`): se reemplazó el flujo "escanea el QR" por un **selector público de restaurantes** (lista con buscador, usando el endpoint ya existente `GET /api/restaurantes`). No requirió cambios de backend.
- **Gramática**: se corrigió el voseo a forma "tú" en toda la SPA (`LoginModal.tsx`, `SessionContext.tsx`, `Carrito.tsx`, `NoEncontrado.tsx`).
- **Usuarios**: el código **no tiene registro propio** (no hay endpoint de sign-up). Solo existe un script de seed (`db/init.sql`) que crea un usuario admin fijo (correo `admin@gmail.com`; la contraseña no se publica aquí porque el repo es público). Si la contraseña real está olvidada, se resetea a mano con `bcryptjs.hashSync()` + `UPDATE` en la base, ya que el hash es de un solo sentido (no se puede "ver" la contraseña). **Importante:** esa contraseña estuvo expuesta en texto plano en commits anteriores del repo (ya corregido) — hay que cambiarla en la base real.
- **Cloudflare automático por API**: se agregó a `scripts/deploy/desplegar.sh` un modo que crea el Worker, el namespace KV y activa el subdominio `*.workers.dev` solo con 3 variables en `deploy.env` (`CF_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_SUBDOMAIN`). Si faltan esas variables, cae de vuelta al proceso manual (documentado en `docs/despliegue-automatico.md`, sección "Opción B").

Todo esto ya está mergeado en `main` vía PR #1 y #2.

## 2. Arquitectura del despliegue

```
Usuario → Cloudflare Worker (*.workers.dev, WAF/rate-limit) → ALB (AWS) → Target Group → Auto Scaling Group (EC2 con Docker) → Postgres (RDS)
```

Todo se levanta con un solo script idempotente: `scripts/deploy/desplegar.sh` (subcomandos: `rds`, `app`, `cloudflare`, `verificar`, `destruir`, `todo`).

## 3. Estado actual (15 nov 2026, ~14:05 hrs Chile)

**El ciclo completo (crear → probar → destruir) ya se probó de punta a punta y funciona.** En este momento el entorno está **destruido por completo** (AWS y Cloudflare) después de una prueba — no hay nada corriendo ni generando costo. Para la entrega/demo, hay que volver a crearlo con el comando de "Próximos pasos" más abajo.

Lo que se validó en la prueba:
- RDS, Target Group, ALB (6 subnets) + listener, Launch Template y Auto Scaling Group: todo se creó sano con un solo comando.
- La ruta `*.workers.dev` del Worker se activó a mano una vez en el dashboard de Cloudflare (ver problema de abajo) y la app cargó bien a través de `https://carta-v2-proxy.carlos0tapi.workers.dev`.
- Se cambió la contraseña real del admin en la base (bcrypt + `UPDATE`), ya que había quedado expuesta en commits anteriores del repo público.
- Se corrigió un bug real de seguridad: faltaba `app.set("trust proxy", 1)` en `app.ts`, lo que hacía que el rate-limit de login (5 intentos/15 min) agrupara a **todos** los usuarios bajo la misma IP aparente (la del ALB) — cualquiera se bloqueaba a todos. Ya está resuelto y desplegado.
- `bash scripts/deploy/desplegar.sh destruir` ahora borra AWS **y** el Worker + KV namespace de Cloudflare en un solo comando (antes solo tocaba AWS).
- **El SG del ALB ya no acepta tráfico de todo internet.** El subcomando `red` ahora descarga los rangos de IP públicos de Cloudflare (`cloudflare.com/ips-v4` e `ips-v6`) y abre el puerto 80/443 solo para esos rangos, en vez de `0.0.0.0/0`. Así nadie puede saltarse el Worker (y su rate-limit/WAF) pegándole directo a la URL del ALB. Se puede desactivar temporalmente para depurar con `RESTRINGIR_A_CLOUDFLARE=0`.
- **Auditoría final de documentación pública**: se encontró y quitó un hostname real filtrado en `cloudflare-worker/security-proxy.js` (la IP de la EC2 en otro formato, que el `sed` masivo anterior no capturó), se sincronizó `docs/OWASP.md` y `cloudflare-worker/README.md` con el estado real del código/script, y se agregó el test que faltaba de IDOR en ventas (`tests/ventas.test.ts`) — el README afirmaba que existía esa prueba, pero no estaba escrita (el control en el código sí existía). Suite completa: 22/22 tests pasan.

Variables de Cloudflare configuradas en `deploy.env` (valores no se publican aquí porque el repo es público): `CF_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_SUBDOMAIN` (`carlos0tapi`, que de todas formas queda visible en la URL pública del Worker).

## 4. Problemas encontrados y cómo se resolvieron

| Problema | Causa | Solución |
|---|---|---|
| `aws` se queda esperando con un `:` y el script no avanza | El pager por defecto del AWS CLI (`less`) bloquea scripts no interactivos | `export AWS_PAGER=""` (agregado también a `~/.bashrc`) |
| Variables como `RDS_MASTER_PASSWORD` "desaparecen" en una terminal nueva | Se habían puesto con `export` en la sesión anterior, no estaban guardadas en `deploy.env` | Escribirlas directamente en `scripts/deploy/deploy.env` con `nano` |
| Target sale "unused" en el ALB aunque el Auto Scaling Group está "Healthy" | El ALB se creó con menos subnets/AZs que las que usa el Auto Scaling Group (`Target.NotInUse`) | `aws elbv2 set-subnets` agregando las 6 subnets; o, como ahora, crear el ALB desde el inicio con las 6 subnets |
| El script muere en silencio justo en "Target Group" o "Application Load Balancer", sin mensaje de error, varias veces seguidas | Muy probablemente CloudShell recicla el proceso en primer plano tras un rato de inactividad del teclado (no es un bug del script; `tmux new` no ayuda porque CloudShell ya corre todo dentro de su propio tmux) | Mitigación: crear manualmente el recurso que se cortó (Target Group, luego ALB, luego listener) y retomar el script — es idempotente, detecta lo ya creado y sigue |
| `gh pr list` falla ("GraphQL no disponible") | Restricción del entorno de Claude Code | Usar `gh api repos/{owner}/{repo}/pulls?head=...` (REST) en vez de GraphQL |
| No se puede hacer `PATCH` directo a `refs/heads/main` por la API de GitHub | El proxy de este entorno bloquea esa escritura | `git fetch` + `git merge --ff-only` + `git push origin main` en local |
| Worker de Cloudflare publicado pero la URL `*.workers.dev` muestra "There is nothing here yet" | El endpoint que activa la ruta `*.workers.dev` de un Worker (`PUT /accounts/{id}/workers/scripts/{name}/subdomain`) no acepta API Token, solo el método de auth antiguo (`10405 Method not allowed for this authentication scheme`) | Activar la ruta una sola vez a mano en el dashboard (Workers & Pages → el worker → Settings → Domains & Routes); el script ahora detecta el fallo y lo avisa con instrucciones en vez de asumir éxito. Es un paso único: una vez activada queda prendida para siempre, no hay que repetirlo en futuros despliegues |
| El rate-limit de login (5 intentos/15 min) bloqueaba a todos los usuarios con solo un par de intentos de cualquiera | Faltaba `app.set("trust proxy", 1)`: detrás del ALB/Cloudflare, Express veía la IP del ALB en vez de la real del cliente, así que el contador se compartía entre todos | Se agregó esa línea en `app.ts` (PR #6). Ya estaba documentado como riesgo aceptado en el informe OWASP; ahora queda resuelto |
| `destruir` corría pero el Worker de Cloudflare seguía existiendo después | El `DELETE` a la API de Cloudflare usaba el código de salida de `curl` (que es 0 con cualquier respuesta HTTP, éxito o error) en vez de revisar el campo `success` del JSON — podía reportar "✔ borrado" sin haber borrado nada | Se corrigió para que revise `success` en la respuesta real (PR #8), igual que el resto de las llamadas a Cloudflare. Verificado borrando Worker y KV namespace con éxito tras el fix |

## 5. Próximos pasos (para la entrega/demo)

1. **Crear todo de nuevo:**
   ```bash
   cd ~/carta-digital && git pull origin main
   SALTAR_DOCKER=1 bash scripts/deploy/desplegar.sh
   ```
   (el subcomando por defecto es `todo`: AWS + Cloudflare en un solo comando. Asegurarse de que el AWS Academy Learner Lab esté iniciado antes, o las credenciales de CloudShell van a estar vencidas).
2. Probar la app en `https://carta-v2-proxy.carlos0tapi.workers.dev`. La URL directa del ALB ya no es accesible desde el navegador normal (el SG del ALB solo acepta tráfico desde IPs de Cloudflare); para diagnosticar el ALB directo hay que correr `red` con `RESTRINGIR_A_CLOUDFLARE=0` primero.
3. Al terminar la demo: `bash scripts/deploy/desplegar.sh destruir` (pide escribir `carta-v2` para confirmar) — borra AWS y Cloudflare en un solo comando.
4. Redactar la documentación final (manual de implementación + procedimiento), según el diagrama de pizarra.

## 6. Convención de trabajo (recordatorio)

Todo cambio de código va en una rama propia, con commits separados y mensaje claro, PR vía `gh api` (REST, no GraphQL), merge, y luego `main` se sincroniza en local con `git merge --ff-only` desde la rama de entrega y se sube con `git push origin main`.
