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
  }

  post {
    always {
      script {
        // CHANGE_ID solo existe en builds de Pull Request (lo define el
        // plugin GitHub Branch Source). Si no esta seteado, este build es
        // de la propia rama main — osea, corrio DESPUES de un merge.
        def esPR = env.CHANGE_ID != null
        def alcance = esPR
          ? "Pull Request #${env.CHANGE_ID} (${env.CHANGE_BRANCH} -> ${env.CHANGE_TARGET})"
          : "rama ${env.BRANCH_NAME} (post-merge)"

        def cambios = sh(
          script: esPR
            ? "git diff --name-status origin/${env.CHANGE_TARGET}...HEAD 2>/dev/null || true"
            : "git diff --name-status HEAD~1 HEAD 2>/dev/null || true",
          returnStdout: true
        ).trim()

        emailext(
          to: 'carlos0tapi@gmail.com',
          subject: "[Carta Digital] ${currentBuild.currentResult}: ${alcance}",
          body: """Resultado: ${currentBuild.currentResult}
Alcance: ${alcance}
Commit: ${env.GIT_COMMIT}
Log completo: ${env.BUILD_URL}console

Archivos modificados:
${cambios ?: '(sin cambios detectados)'}
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
