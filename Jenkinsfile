// Pipeline de CI (2da parte del proyecto): Jenkins es un VERIFICADOR, no un
// desplegador. Corre en cada Pull Request hacia main (y de nuevo, mas liviano,
// despues de cada merge a main) y reporta el resultado como check del PR.
//
// El merge en si lo decide GitHub: ademas de este check en verde, la rama
// main exige al menos 1 aprobacion humana (branch protection, ver
// docs/jenkins.md). Jenkins no aprueba ni bloquea el merge por si mismo, ni
// despliega nada automaticamente — eso es deliberado, ver docs/jenkins.md.
//
// Requiere un Job tipo "Multibranch Pipeline" con el plugin GitHub Branch
// Source (Discover branches + Discover pull requests): asi cada build se
// publica solo como check en el Pull Request correspondiente, sin codigo
// adicional en este Jenkinsfile. El disparador es "Periodically if not
// otherwise run" (polling), no un webhook publico — Jenkins no necesita
// quedar expuesto a internet para esto (ver docs/jenkins.md).
pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  environment {
    IMAGEN_NODE = 'node:20-alpine'
    RED_PRUEBA  = "ci-${env.BUILD_TAG}"
    DB_PRUEBA   = "ci-db-${env.BUILD_TAG}"
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Instalar dependencias y build') {
      steps {
        sh '''
          docker run --rm -v "$WORKSPACE:/app" -w /app "$IMAGEN_NODE" \
            sh -c "npm ci && npm run build"
        '''
      }
    }

    stage('Tests (con Postgres temporal)') {
      steps {
        sh '''
          docker network create "$RED_PRUEBA"
          docker run -d --name "$DB_PRUEBA" --network "$RED_PRUEBA" \
            -e POSTGRES_DB=carta_digital_test -e POSTGRES_USER=carta_test \
            -e POSTGRES_PASSWORD=jenkins_test_only_2026 postgres:17-alpine
          for i in $(seq 1 30); do
            docker exec "$DB_PRUEBA" pg_isready -U carta_test -d carta_digital_test >/dev/null 2>&1 && break
            sleep 2
          done
          docker run --rm --network "$RED_PRUEBA" -v "$WORKSPACE:/app" -w /app \
            -e TEST_PGHOST="$DB_PRUEBA" "$IMAGEN_NODE" npm test
        '''
      }
      post {
        always {
          sh 'docker rm -f "$DB_PRUEBA" >/dev/null 2>&1 || true; docker network rm "$RED_PRUEBA" >/dev/null 2>&1 || true'
        }
      }
    }

    stage('Seguridad: secretos filtrados (gitleaks)') {
      steps {
        sh '''
          docker run --rm -v "$WORKSPACE:/repo" zricethezav/gitleaks:latest \
            detect --source=/repo --no-git -v
        '''
      }
    }

    stage('Seguridad: dependencias vulnerables (npm audit)') {
      steps {
        sh '''
          docker run --rm -v "$WORKSPACE:/app" -w /app "$IMAGEN_NODE" \
            npm audit --omit=dev --audit-level=high
        '''
      }
    }

    stage('Seguridad: OWASP Top 10 (Semgrep)') {
      steps {
        sh '''
          docker run --rm -v "$WORKSPACE:/src" returntocorp/semgrep:latest \
            semgrep scan --config p/owasp-top-ten --error --metrics=off /src
        '''
      }
    }

    // Complementa a npm audit (arriba): npm audit es rapido y especifico
    // para paquetes de npm; esta etapa consulta la base NVD completa y
    // genera un reporte HTML/JSON detallado por cada hallazgo (CVE,
    // severidad, CVSS) que se adjunta al email al final del pipeline (ver
    // el bloque "post" mas abajo) — pensado para usarse como evidencia,
    // no solo como pass/fail. A diferencia de las otras etapas de
    // seguridad, esta NO hace fallar el build por si sola (Dependency-Check
    // puede marcar falsos positivos por como identifica las librerias): si
    // mas adelante se quiere que tambien bloquee el merge, se le puede
    // agregar el flag --failOnCVSS <puntaje> mas abajo.
    //
    // IMPORTANTE: la NVD_API_KEY (ver docs/jenkins.md) NO es solo una
    // optimizacion de velocidad — desde que la NVD exige la key para
    // cualquier consulta (incluida la primera descarga de su base de
    // CVEs), sin ella esta etapa literalmente no tiene datos para
    // analizar. El "|| true" de abajo evita que esto tumbe el pipeline
    // completo (consistente con que esta etapa es informativa), pero
    // sin la key el reporte va a salir vacio o directamente no se va a
    // generar — no es un bug, es la etapa degradando con gracia.
    stage('Seguridad: reporte de dependencias (OWASP Dependency-Check)') {
      steps {
        sh '''
          rm -rf reporte-dependencias && mkdir -p reporte-dependencias
          NVD_ARGS=""
          if [ -n "${NVD_API_KEY:-}" ]; then
            NVD_ARGS="--nvdApiKey $NVD_API_KEY"
          fi
          docker run --rm \
            -v "$WORKSPACE:/src" \
            -v dependency-check-data:/usr/share/dependency-check/data \
            owasp/dependency-check:latest \
            --scan /src --out /src/reporte-dependencias \
            --format HTML --format JSON \
            --project "Carta Digital" \
            --exclude "**/node_modules/**" \
            $NVD_ARGS || echo "OWASP Dependency-Check no pudo terminar (ver log arriba) — no bloquea el pipeline, es informativo."
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: 'reporte-dependencias/*', allowEmptyArchive: true
        }
      }
    }
  }

  post {
    always {
      script {
        // CHANGE_ID solo existe en builds de Pull Request (lo define el
        // plugin GitHub Branch Source). Si no esta seteado, este build es
        // de la propia rama main — osea, corrio DESPUES de un merge.
        def esPR = env.CHANGE_ID != null
        def alcance = esPR
          ? "el Pull Request #${env.CHANGE_ID} (de la rama '${env.CHANGE_BRANCH}' hacia '${env.CHANGE_TARGET}')"
          : "la rama '${env.BRANCH_NAME}' (recien actualizada por un merge)"

        def cambios = sh(
          script: esPR
            ? "git diff --name-only origin/${env.CHANGE_TARGET}...HEAD 2>/dev/null || true"
            : "git diff --name-only HEAD~1 HEAD 2>/dev/null || true",
          returnStdout: true
        ).trim()
        def listaArchivos = cambios
          ? cambios.readLines().collect { "  - ${it}" }.join("\n")
          : "  (no se detectaron archivos modificados)"

        def paso = currentBuild.currentResult == 'SUCCESS'

        // Resumen del reporte de OWASP Dependency-Check (una linea,
        // "<total>|<severidad: cantidad, ...>") para mostrar en el cuerpo
        // del email sin tener que abrir el adjunto HTML. Si la etapa no
        // llego a correr (ej. fallo algo antes), igual se intenta leer el
        // reporte por si quedo de un intento anterior; si no hay nada,
        // el script de resumen avisa "el reporte no se generó".
        def depResumenCrudo = sh(
          script: 'docker run --rm -v "$WORKSPACE:/app" -w /app "$IMAGEN_NODE" node scripts/jenkins/resumen-dependency-check.js 2>/dev/null || echo "0|no se pudo leer el reporte"',
          returnStdout: true
        ).trim()
        def depPartes = depResumenCrudo.tokenize('|')
        def depTotal = depPartes.size() > 0 ? depPartes[0] : '0'
        def depDetalle = depPartes.size() > 1 ? depPartes[1] : 'sin datos'

        // Resumen en lenguaje simple: pensado para que lo pueda leer
        // cualquiera, no solo alguien del equipo tecnico.
        def resumen = paso
          ? """RESULTADO: todo en orden ✅

Se revisó automáticamente el código de ${alcance} y pasó los 5 controles:
  ✔ El proyecto compila sin errores
  ✔ Las pruebas automáticas pasaron (incluyen seguridad: inicio de sesión,
    permisos de administrador, protección contra ataques comunes)
  ✔ No se encontraron contraseñas ni claves secretas filtradas en el código
  ✔ No se detectaron librerías externas con vulnerabilidades conocidas
  ✔ No se encontraron patrones de riesgo del OWASP Top 10 (inyección,
    configuración insegura, etc.) en el código

No hace falta ninguna acción: este cambio está listo para que una persona
del equipo lo revise y, si corresponde, lo apruebe en GitHub."""
          : """RESULTADO: encontramos un problema ⚠️

Se revisó automáticamente el código de ${alcance} y uno de los controles
NO pasó (puede ser que el código no compile, que alguna prueba automática
haya fallado, que se haya filtrado una contraseña/clave, que una librería
externa tenga una vulnerabilidad conocida, o que se haya detectado un
patrón de riesgo del OWASP Top 10).

Por ahora este cambio no debería aprobarse ni mergearse. Alguien del
equipo técnico tiene que revisar el detalle (link más abajo) antes de
seguir adelante."""

        emailext(
          to: 'carlos0tapi@gmail.com',
          subject: "[Carta Digital] ${paso ? '✅ Todo OK' : '⚠️ Hay un problema'} — ${esPR ? 'PR #' + env.CHANGE_ID : 'rama ' + env.BRANCH_NAME}",
          attachmentsPattern: 'reporte-dependencias/dependency-check-report.html',
          body: """${resumen}

Reporte de dependencias (OWASP Dependency-Check): ${depTotal} vulnerabilidad(es) encontradas (${depDetalle}).
Este control es informativo, no bloquea el merge por sí solo — el reporte completo, con el detalle de cada hallazgo (CVE, severidad, librería afectada), va adjunto a este correo en HTML (se abre en cualquier navegador).

Archivos que cambiaron en este envío:
${listaArchivos}

-------------------------------------------
Detalles técnicos (para el equipo de desarrollo):
Resultado: ${currentBuild.currentResult}
Commit: ${env.GIT_COMMIT}
Log completo: ${env.BUILD_URL}console
"""
        )
      }
    }
    success {
      echo 'Verificacion OK (el merge sigue necesitando al menos 1 aprobacion humana en GitHub).'
    }
    failure {
      echo 'Verificacion FALLIDA — revisar el log de la etapa que fallo. GitHub bloqueara el merge mientras este check este en rojo.'
    }
  }
}
