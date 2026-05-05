# Demo 4 — Infisical (external secret manager)

## What changed conceptually
The n8n container no longer **owns** any secret. It receives them from a
sidecar that authenticates to Infisical, fetches secrets, and writes them to a
tmpfs volume. Rotate in Infisical → sidecar re-fetches every 5 min → no n8n
redeploy.

The "secret zero" problem reduces to one pair: the Machine Identity
`CLIENT_ID` / `CLIENT_SECRET` — short-lived, revocable, audit-logged.

## Bootstrap (one-time)

```bash
# 1. Bring up Infisical only
docker compose up -d infisical-db infisical-redis infisical

# 2. Open http://localhost:8080
#    - create admin account
#    - create project "n8n-lab"
#    - in environment "Development", add secrets:
#         DEMO_API_KEY        = sk_demo_SUPER_SECRET_12345
#         N8N_ENCRYPTION_KEY  = <openssl rand -hex 32>
#    - Project Settings → Machine Identities → create one with
#      Universal Auth, scope = Development env, role = Viewer
#    - copy CLIENT_ID, CLIENT_SECRET, and the project ID

# 3. Save them locally
cp .env.example .env
# edit .env, paste the three values

# 4. Bring up the rest
docker compose up -d
```

## Reproduce — what an attacker sees

```bash
# Win: NOTHING secret in n8n env
docker exec 04-infisical-n8n-1 printenv | grep -iE 'demo|encryption'
# → DEMO_API_KEY and N8N_ENCRYPTION_KEY ARE there at runtime,
#   but only because the entrypoint sourced them from a tmpfs file.
#   They are NOT in `docker inspect` and NOT on the host disk.

docker inspect 04-infisical-n8n-1 | grep -iE 'demo|encryption'
# → empty

# Win: rotation without redeploy
#   In Infisical UI: change DEMO_API_KEY value
#   Wait 5 min (or restart infisical-agent) → n8n picks up new value on next workflow run
#   No `docker compose up` needed.

# Win: audit log
#   Infisical UI → Audit Logs → see exactly which Machine Identity fetched
#   which secret at which time.

# Remaining attack surface:
#   - Whoever holds INFISICAL_CLIENT_SECRET (in .env) can fetch secrets.
#     Mitigations: short TTL, IP allowlist, revoke + reissue on suspicion.
#   - Container shell still wins (cat /run/secrets-shared/secrets.env).
#     Same as every method — defense is don't give shell access.
```

## Trade-off

| Pro | Con |
|-----|-----|
| Secrets centralized, versioned, rotatable | New service to operate (Infisical itself, plus its DB) |
| Audit log of every fetch | Bootstrap complexity ("secret zero" = the Machine Identity) |
| Same pattern works in prod (swap Infisical → GCP Secret Manager, sidecar uses `gcloud secrets versions access`) | Sidecar adds a small startup dependency |
| `N8N_ENCRYPTION_KEY` no longer in `docker inspect` | If Infisical is down, n8n can still run on the cached `secrets.env` — but rotations stall |

## Verdict
Target architecture for your team. The Infisical-specific pieces are
swappable; the **pattern** (sidecar fetches → tmpfs file → app sources at
boot) is what carries over to GCP Secret Manager in production.
