#!/usr/bin/env bash
# Bootstraps Infisical from a freshly-booted state via REST API:
#   admin signup → project → secrets → Machine Identity → Universal Auth creds
# Writes INFISICAL_CLIENT_ID / SECRET / PROJECT_ID into ./.env
#
# Idempotent for the .env step only — re-running on a populated Infisical
# will fail at signup. Use `make down DEMO=4 && make up-4a` to reset.

set -euo pipefail

INF_URL="${INF_URL:-http://localhost:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local.test}"
ADMIN_PW="${ADMIN_PW:-Demo1234!}"
PROJECT_NAME="${PROJECT_NAME:-n8n-lab}"
ENV_SLUG="${ENV_SLUG:-dev}"
DEMO_API_KEY="${DEMO_API_KEY:-sk_demo_SUPER_SECRET_12345}"
N8N_KEY="${N8N_KEY:-$(openssl rand -hex 32)}"

curl_json() { curl -sS -H "Content-Type: application/json" "$@"; }
auth() { curl_json -H "Authorization: Bearer $TOKEN" "$@"; }

say() { printf "\033[36m▸\033[0m %s\n" "$*"; }

# ---------- 1. admin signup ----------
say "1/6  admin signup"
SIGNUP=$(curl_json -X POST "$INF_URL/api/v1/admin/signup" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PW\",\"firstName\":\"Demo\",\"lastName\":\"Admin\"}")
if echo "$SIGNUP" | grep -q '"already been set up"'; then
  echo "  admin already exists — please 'make down DEMO=4' first to re-bootstrap"
  exit 1
fi
TOKEN=$(echo "$SIGNUP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
ORG_ID=$(echo "$SIGNUP" | python3 -c "import sys,json; print(json.load(sys.stdin)['organization']['id'])")
echo "  org: $ORG_ID"

# ---------- 2. scope token to org ----------
say "2/6  scope token to org"
TOKEN=$(curl_json -X POST "$INF_URL/api/v3/auth/select-organization" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"organizationId\":\"$ORG_ID\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# ---------- 3. create project ----------
say "3/6  create project '$PROJECT_NAME'"
PROJ=$(auth -X POST "$INF_URL/api/v2/workspace" \
  -d "{\"projectName\":\"$PROJECT_NAME\",\"slug\":\"$PROJECT_NAME\",\"type\":\"secret-manager\"}")
PROJECT_ID=$(echo "$PROJ" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('project',d).get('id',''))")
echo "  project id: $PROJECT_ID"
test -n "$PROJECT_ID" || { echo "project create failed: $PROJ"; exit 1; }

# ---------- 4. add secrets ----------
say "4/6  add secrets to env '$ENV_SLUG'"
for kv in "DEMO_API_KEY=$DEMO_API_KEY" "N8N_ENCRYPTION_KEY=$N8N_KEY"; do
  k=${kv%%=*}; v=${kv#*=}
  resp=$(auth -X POST "$INF_URL/api/v3/secrets/raw/$k" \
    -d "{\"workspaceId\":\"$PROJECT_ID\",\"environment\":\"$ENV_SLUG\",\"secretValue\":\"$v\",\"secretPath\":\"/\",\"type\":\"shared\"}")
  if echo "$resp" | grep -q '"id"'; then echo "  + $k"; else echo "  ! $k failed: $resp"; fi
done

# ---------- 5. create Machine Identity ----------
say "5/6  create Machine Identity"
# Find the org admin role id (we need a role to assign at org level)
ROLE_ID=$(auth "$INF_URL/api/v1/organization/$ORG_ID/roles" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['roles']; print([x['id'] for x in r if x['slug']=='admin'][0])")

MI=$(auth -X POST "$INF_URL/api/v1/identities" \
  -d "{\"name\":\"n8n-sidecar\",\"organizationId\":\"$ORG_ID\",\"role\":\"$ROLE_ID\"}")
MI_ID=$(echo "$MI" | python3 -c "import sys,json; print(json.load(sys.stdin)['identity']['id'])")
echo "  identity id: $MI_ID"

# Attach Universal Auth
auth -X POST "$INF_URL/api/v1/auth/universal-auth/identities/$MI_ID" \
  -d "{\"clientSecretTrustedIps\":[{\"ipAddress\":\"0.0.0.0/0\"}],\"accessTokenTrustedIps\":[{\"ipAddress\":\"0.0.0.0/0\"}],\"accessTokenTTL\":2592000,\"accessTokenMaxTTL\":2592000,\"accessTokenNumUsesLimit\":0}" \
  > /tmp/inf.ua.json
CLIENT_ID=$(python3 -c "import json; print(json.load(open('/tmp/inf.ua.json'))['identityUniversalAuth']['clientId'])")

# Mint a client secret
SEC=$(auth -X POST "$INF_URL/api/v1/auth/universal-auth/identities/$MI_ID/client-secrets" \
  -d "{\"description\":\"bootstrap\",\"ttl\":0,\"numUsesLimit\":0}")
CLIENT_SECRET=$(echo "$SEC" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientSecret'])")

# Grant the MI access to the project
say "5b/6 add identity to project"
auth -X POST "$INF_URL/api/v2/workspace/$PROJECT_ID/identity-memberships/$MI_ID" \
  -d "{\"role\":\"admin\"}" > /dev/null || true

# ---------- 6. write .env ----------
say "6/6  write .env"
cat > "$(dirname "$0")/.env" <<EOF
INFISICAL_CLIENT_ID=$CLIENT_ID
INFISICAL_CLIENT_SECRET=$CLIENT_SECRET
INFISICAL_PROJECT_ID=$PROJECT_ID
EOF
echo ""
echo "✓ done — Infisical is bootstrapped."
echo "  admin login: $ADMIN_EMAIL / $ADMIN_PW   (http://localhost:8080)"
echo "  next: make up-4b"
