#!/usr/bin/env bash
# deploy.sh — Déploie le workflow "Sync Affectation Véhicules" sur n8n Cloud
#
# Usage:
#   WEBHOOK_SECRET="ma_cle_secrete" bash deploy.sh
#
# Variables requises (lues depuis .env si présent, sinon depuis l'environnement) :
#   N8N_API_KEY      — JWT généré dans n8n Settings > API
#   N8N_API_URL      — Base URL de l'API (ex: https://iasomafi.app.n8n.cloud/api/v1)
#   WEBHOOK_SECRET   — La valeur de X-API-Key que les appelants devront envoyer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Charger le .env si présent
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

: "${N8N_API_URL:?Variable N8N_API_URL manquante}"
: "${N8N_API_KEY:?Variable N8N_API_KEY manquante}"
: "${WEBHOOK_SECRET:?Variable WEBHOOK_SECRET manquante (valeur X-API-Key pour le webhook)}"

WORKFLOW_FILE="$SCRIPT_DIR/workflows/sync_affectation_vehicules.json"

header() { echo ""; echo "=== $* ==="; }
ok()     { echo "  ✓ $*"; }
err()    { echo "  ✗ ERREUR: $*" >&2; exit 1; }

header "1. Recherche du credential Google Sheets existant"
CREDS_RESPONSE=$(curl -sf "$N8N_API_URL/credentials" \
  -H "X-N8N-API-KEY: $N8N_API_KEY")

GSHEETS_ID=$(echo "$CREDS_RESPONSE" | python3 - <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
items = data.get("data", data) if isinstance(data, dict) else data
for c in (items if isinstance(items, list) else []):
    if c.get("type") == "googleSheetsOAuth2Api":
        print(c["id"])
        break
PYEOF
)

GSHEETS_NAME=$(echo "$CREDS_RESPONSE" | python3 - <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
items = data.get("data", data) if isinstance(data, dict) else data
for c in (items if isinstance(items, list) else []):
    if c.get("type") == "googleSheetsOAuth2Api":
        print(c["name"])
        break
PYEOF
)

[ -n "$GSHEETS_ID" ] || err "Aucun credential 'googleSheetsOAuth2Api' trouvé dans n8n.\nCrée d'abord un credential Google Sheets OAuth2 dans n8n Settings > Credentials."
ok "Credential Google Sheets : \"$GSHEETS_NAME\" (id=$GSHEETS_ID)"

header "2. Création du credential Header Auth 'Webhook Somafi Sync'"

# Vérifier si le credential existe déjà
EXISTING_HEADER=$(echo "$CREDS_RESPONSE" | python3 - <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
items = data.get("data", data) if isinstance(data, dict) else data
for c in (items if isinstance(items, list) else []):
    if c.get("name") == "Webhook Somafi Sync" and c.get("type") == "httpHeaderAuth":
        print(c["id"])
        break
PYEOF
)

if [ -n "$EXISTING_HEADER" ]; then
  HEADER_CRED_ID="$EXISTING_HEADER"
  ok "Credential 'Webhook Somafi Sync' déjà existant (id=$HEADER_CRED_ID) — réutilisé"
else
  HEADER_RESP=$(curl -sf -X POST "$N8N_API_URL/credentials" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"Webhook Somafi Sync\",
      \"type\": \"httpHeaderAuth\",
      \"data\": {\"name\": \"X-API-Key\", \"value\": \"$WEBHOOK_SECRET\"}
    }")
  HEADER_CRED_ID=$(echo "$HEADER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  ok "Credential créé (id=$HEADER_CRED_ID)"
fi

header "3. Injection des IDs de credentials dans le workflow"
WORKFLOW_JSON=$(sed \
  -e "s/HEADER_AUTH_CRED_ID/$HEADER_CRED_ID/g" \
  -e "s/GSHEETS_CRED_ID/$GSHEETS_ID/g" \
  -e "s/Google Sheets account/$GSHEETS_NAME/g" \
  "$WORKFLOW_FILE")
ok "IDs injectés (headerAuth=$HEADER_CRED_ID, gsheets=$GSHEETS_ID)"

header "4. Push du workflow vers n8n"
WORKFLOW_RESP=$(curl -sf -X POST "$N8N_API_URL/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$WORKFLOW_JSON")

WORKFLOW_ID=$(echo "$WORKFLOW_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
[ -n "$WORKFLOW_ID" ] || err "La création du workflow a échoué.\nRéponse: $WORKFLOW_RESP"
ok "Workflow créé (id=$WORKFLOW_ID)"

header "5. Activation du workflow"
ACTIVATE_RESP=$(curl -sf -X POST "$N8N_API_URL/workflows/$WORKFLOW_ID/activate" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json")
ok "Workflow activé"

# Sauvegarder l'ID dans .env.deployed
echo "N8N_WORKFLOW_ID=$WORKFLOW_ID" >> "$SCRIPT_DIR/.env.deployed" 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Déploiement terminé avec succès !"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Workflow ID  : $WORKFLOW_ID"
echo "  Webhook URL  : https://iasomafi.app.n8n.cloud/webhook/sync-affectation-vehicules"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Test rapide :"
echo "  curl -s -X POST https://iasomafi.app.n8n.cloud/webhook/sync-affectation-vehicules \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H \"X-API-Key: \$WEBHOOK_SECRET\" \\"
echo "    -d '{\"data\":[{\"Immatriculation\":\"AA-123-BB\",\"Agence\":\"Paris\"}]}'"
echo ""
