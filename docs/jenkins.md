# Jenkins — verificador de Pull Requests

<!-- Nota de prueba (PR de verificación): este comentario no cambia nada del
     comportamiento del pipeline. Solo sirve para generar un commit real y
     así poder abrir un Pull Request de prueba, que Jenkins va a detectar y
     correr completo (incluyendo las etapas de Semgrep y Dependency-Check),
     para confirmar que todo funciona de punta a punta antes de usarlo en
     Pull Requests reales. Se puede borrar este comentario cuando se cierre
     ese PR de prueba. -->


Jenkins acá **no despliega nada**. Es un segundo par de ojos automático: cada
vez que alguien abre o actualiza un Pull Request hacia `main`, Jenkins
compila, corre las pruebas y busca secretos filtrados o dependencias
vulnerables. El resultado aparece como un check en el propio Pull Request.

La decisión de mergear sigue siendo de un humano: GitHub exige además **al
menos 1 aprobación** antes de habilitar el botón de "Merge" (ver
"Branch protection" más abajo). Jenkins no aprueba ni decide nada por su
cuenta — solo valida y avisa, por el check en GitHub y por email.

## Por qué así (y no como en la entrega anterior)

El repo tenía un `Jenkinsfile` de una entrega previa que, al final del
pipeline, se conectaba por SSH a un servidor fijo y desplegaba ahí. Eso ya
no aplica: desde que migramos a AWS con Auto Scaling + Load Balancer + RDS
(ver `docs/despliegue-automatico.md`), no hay un servidor único al que
conectarse — las instancias de la app son efímeras y se crean/destruyen
solas. El `Jenkinsfile` actual reemplaza por completo ese enfoque.

## 1. Desplegar la instancia de Jenkins

Jenkins corre en su **propia EC2**, separada de las instancias de la app
(si se mezclaran, un *instance refresh* del Auto Scaling de la app borraría
la configuración de Jenkins).

```bash
cp scripts/jenkins/jenkins.env.example scripts/jenkins/jenkins.env   # completar MI_IP
bash scripts/jenkins/desplegar-jenkins.sh            # = verificar → red → jenkins → password
```

El security group solo deja entrar al puerto 8080 (panel de Jenkins) desde
tu propia IP (`MI_IP` en `jenkins.env`) — **no está abierto a internet**.
Por eso el Job de GitHub usa *polling* en vez de un webhook público (ver
paso 3): no hace falta que GitHub pueda alcanzar a Jenkins desde afuera.

Al final el script intenta mostrar la contraseña inicial de administrador
leyendo la consola de la instancia (puede tardar unos minutos en aparecer).
Si no aparece, el mensaje del script te da el comando manual para sacarla
por SSH/EC2 Instance Connect.

> **Esta instancia es persistente**, igual que la RDS de la app: no la
> destruyas entre pruebas o perdés toda la configuración de Jenkins (jobs,
> credenciales, historial). `scripts/jenkins/desplegar-jenkins.sh destruir`
> solo está pensado para cuando termines de verdad con el proyecto.
>
> La instancia usa una **IP elástica** (no la IP pública dinámica que AWS
> asigna por defecto): si el Lab de AWS Academy se corta y la instancia se
> reinicia, la URL de Jenkins **no cambia**. La IP elástica sobrevive incluso
> a un `destruir` (se reutiliza en el próximo `jenkins`/`todo`); para
> liberarla del todo usá `desplegar-jenkins.sh liberar-ip`.

## 2. Primer login y plugins

1. Entrá a `http://<IP>:8080`, pegá la contraseña inicial, instalá los
   plugins sugeridos.
2. Instalá además estos dos plugins (Manage Jenkins → Plugins → Available):
   - **GitHub Branch Source** — descubre PRs automáticamente y publica el
     resultado como check en cada uno.
   - **Email Extension Plugin** — para el `emailext` que usa el `Jenkinsfile`.
3. Configurá el email saliente en Manage Jenkins → System →
   Extended E-mail Notification: sos SMTP (ej. `smtp.gmail.com:587`, con
   una [contraseña de aplicación](https://myaccount.google.com/apppasswords)
   de Gmail, nunca tu contraseña normal) y el remitente. El destino
   (`carlos0tapi@gmail.com`) ya está en el `Jenkinsfile`.
4. Generá un Personal Access Token en GitHub (Settings → Developer settings
   → Fine-grained tokens) con permiso de lectura sobre el repo, y cargalo en
   Jenkins como credencial (Manage Jenkins → Credentials) — lo vas a usar en
   el paso 3.

## 3. Crear el Job (Multibranch Pipeline)

1. New Item → nombre `carta-digital` → tipo **Multibranch Pipeline**.
2. En "Branch Sources" → Add → **GitHub**: pegá la URL del repo y elegí la
   credencial del paso anterior.
3. En "Behaviours" dejá activo "Discover branches" y agregá
   **"Discover pull requests from forks"** (o "from origin" si el
   colaborador va a trabajar directo sobre el repo, sin fork).
4. En "Scan Multibranch Pipeline Triggers" activá **"Periodically if not
   otherwise run"**, cada 2-5 minutos. Esto reemplaza al webhook: Jenkins
   va a buscar PRs nuevos solo, sin que GitHub necesite alcanzarlo.
5. "Build Configuration" → by Jenkinsfile → `Jenkinsfile` (ya está en la
   raíz del repo).
6. Guardar. Jenkins va a escanear el repo, encontrar `main` y cualquier PR
   abierto, y correr el pipeline en cada uno.

## 4. Branch protection en GitHub

Una vez que corrió el pipeline al menos una vez sobre un Pull Request de
prueba, fijate en la pantalla de ese PR qué nombre exacto tiene el check
que publicó Jenkins (sección "Checks" al final del PR). Con eso:

```bash
bash scripts/jenkins/configurar-branch-protection.sh Cira-yt/carta-digital "<nombre-exacto-del-check>"
```

Esto exige, para poder mergear a `main`:
- que ese check esté en verde, y
- al menos 1 aprobación de otro colaborador.

Con `enforce_admins: false` (lo que configura el script por defecto), como
dueño del repo igual podés forzar el merge sin aprobación — útil mientras
probás en solitario. El script te deja el comando para activarlo (exigir la
regla también a los administradores) cuando sumes al colaborador.

**Importante:** GitHub no te deja aprobar tu propio Pull Request (no es una
configuración, es una restricción fija de la plataforma) — por eso el
bypass de administrador es necesario para probar el flujo solo.

## 5. Qué hace el pipeline, paso a paso

Ver el `Jenkinsfile` en la raíz del repo. Resumen:

1. Checkout del commit del PR (o de `main`, si el build es post-merge).
2. `npm ci` + `npm run build`, dentro de un contenedor `node:20-alpine`
   (Jenkins no necesita Node instalado, solo Docker).
3. Levanta un Postgres temporal (mismo patrón que `cmd_docker()` en
   `scripts/deploy/desplegar.sh`) y corre `npm test`.
4. `gitleaks` sobre el código del PR, buscando contraseñas o tokens
   filtrados por error (automatiza lo que al principio del proyecto
   hicimos a mano al auditar el historial de git).
5. `npm audit --omit=dev --audit-level=high` sobre las dependencias de
   producción.
6. `semgrep scan --config p/owasp-top-ten` sobre el código del PR: análisis
   estático (SAST) que busca patrones de riesgo de las categorías del
   [OWASP Top 10](https://owasp.org/www-project-top-ten/) que se pueden
   detectar leyendo el código (inyección, configuración insegura,
   criptografía débil, etc.). No sustituye una revisión completa del Top
   10 (hay categorías, como el control de acceso roto, que dependen del
   contexto de la app y no se detectan solo leyendo el código línea por
   línea — esas las cubren los tests de `npm test`), pero sí automatiza la
   parte que un escáner de este tipo puede cubrir.
7. **OWASP Dependency-Check** sobre las dependencias de producción: a
   diferencia de `npm audit` (rápido, específico para paquetes de npm, base
   de GitHub Advisory Database), este consulta la base NVD completa y
   genera un reporte **HTML** detallado — tabla de dependencias, qué CVE
   tiene cada una, severidad, puntaje CVSS y referencias — pensado como
   evidencia para mostrar, no solo como pass/fail. Por eso esta etapa **no
   hace fallar el build** por sí sola (puede dar falsos positivos por cómo
   identifica las librerías); el reporte igual se adjunta en HTML al email
   del paso 8, y un resumen de una línea (cuántas vulnerabilidades y de qué
   severidad) se agrega al cuerpo del correo.

   **Paso necesario, no solo una optimización** — la NVD cambió su
   política y ahora exige una API key para cualquier consulta a su base de
   CVEs, incluida la primera descarga. Sin la key, esta etapa no tiene
   datos para analizar y el reporte sale vacío (el `|| echo "..."` del
   `Jenkinsfile` evita que esto rompa el pipeline completo, pero el
   reporte en sí no sirve de nada sin la key). Es gratis y rápido de
   conseguir:
   1. Pedila en <https://nvd.nist.gov/developers/request-an-api-key>
      (llega por email, sin costo).
   2. En Jenkins: Manage Jenkins → System → "Global properties" → activar
      "Environment variables" → agregar `NVD_API_KEY` con el valor de la
      key.

   A propósito es una variable de entorno global y no un "credential" de
   Jenkins — así, aunque falte, nunca rompe el pipeline entero (solo deja
   esta etapa sin datos útiles, nunca bloquea el merge).
8. Manda un email con el resultado, los archivos modificados y el link al
   log completo (y el reporte de Dependency-Check adjunto en HTML) — tanto
   si el build es de un PR (antes del merge) como si es de `main` (justo
   después de que alguien mergeó).

Si cualquiera de los pasos 2-6 falla, el pipeline termina en rojo, el check
del PR queda en rojo, y GitHub bloquea el botón de "Merge" aunque ya haya
una aprobación (el paso 7, Dependency-Check, es informativo y no bloquea
por sí solo — ver más arriba).
