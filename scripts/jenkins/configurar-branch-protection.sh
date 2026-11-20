#!/usr/bin/env bash
# =============================================================================
# Configura la regla de protección de la rama `main` en GitHub:
#   - exige que el check de Jenkins esté en verde
#   - exige al menos 1 aprobación humana (que no sea el autor del PR)
#   - deja el bypass de administrador ACTIVADO (para que puedas mergear vos
#     mismo mientras probás en solitario, antes de sumar al colaborador)
#
# Requiere la CLI de GitHub (gh) ya autenticada con permisos de admin sobre
# el repo.
#
# Uso:
#   bash scripts/jenkins/configurar-branch-protection.sh <owner>/<repo> [contexto-del-check]
#
# El "contexto del check" es el nombre exacto con el que Jenkins reporta el
# resultado en el Pull Request. Con el plugin GitHub Branch Source y sin el
# plugin de GitHub Checks instalado, el valor por defecto para builds de PR
# es "continuous-integration/jenkins/pr-merge" — pero ANTES de correr este
# script, hacé un primer Pull Request de prueba, mirá qué nombre de check
# aparece realmente en la pantalla del PR, y pasalo como segundo argumento
# si es distinto.
# =============================================================================
set -euo pipefail

REPO="${1:?Uso: $0 <owner>/<repo> [contexto-del-check]}"
CONTEXTO="${2:-continuous-integration/jenkins/pr-merge}"

echo "Repo: $REPO"
echo "Check requerido: $CONTEXTO"
echo

gh api -X PUT "repos/$REPO/branches/main/protection" \
  --input - <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["$CONTEXTO"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null
}
JSON

echo
echo "Listo. 'enforce_admins: false' significa que vos, como admin del repo,"
echo "todavía podés forzar el merge sin aprobación mientras probás en"
echo "solitario. Cuando sumes al colaborador y quieras que la regla aplique"
echo "también a vos, activá el enforce_admins:"
echo "  gh api -X POST repos/$REPO/branches/main/protection/enforce_admins"
echo "(y para volver a desactivarlo: gh api -X DELETE repos/$REPO/branches/main/protection/enforce_admins)"
