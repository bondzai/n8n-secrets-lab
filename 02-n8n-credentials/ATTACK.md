# Demo 2 — n8n Credentials (encrypted at rest in Postgres)

## Setup

```bash
# 1. Generate a real encryption key
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" > .env

# 2. Start
docker compose up -d

# 3. Open http://localhost:5678, create an account, then:
#    Credentials → New → "Header Auth"
#    Name: demo-key, Value: sk_demo_SUPER_SECRET_12345
```

## Where the secret lives now
- **Not** in `.env`
- **Not** in `docker inspect` (only `N8N_ENCRYPTION_KEY` is)
- In Postgres table `credentials_entity`, column `data` — **AES-256 encrypted**

## Reproduce — what an attacker sees

```bash
# Win: API key is NOT in env
docker exec 02-n8n-credentials-n8n-1 printenv | grep -i demo
# (empty)

# Win: API key is NOT in docker inspect
docker inspect 02-n8n-credentials-n8n-1 | grep -i sk_demo
# (empty)

# Partial loss: encrypted blob in DB
docker exec 02-n8n-credentials-postgres-1 \
  psql -U n8n -d n8n -c "SELECT name, data FROM credentials_entity;"
# → name=demo-key, data=<base64 ciphertext>   (cannot read without key)

# FULL LOSS: attacker who has BOTH the DB dump AND the env key wins
docker exec 02-n8n-credentials-n8n-1 printenv N8N_ENCRYPTION_KEY
# → with this key + the blob above, they decrypt offline
```

## Trade-off

| Pro | Con |
|-----|-----|
| Native n8n UX, per-credential RBAC | The encryption key itself still lives in env (`docker inspect` exposes it) |
| Encrypted at rest — DB backup alone is useless | DB dump **+** env key = total compromise |
| Works with every n8n node | Rotation = re-encrypt every credential (n8n CLI supports it but it's a maintenance event) |
| | No audit log of who used which credential |

## Verdict
The minimum acceptable baseline for a real team. The next demos move
`N8N_ENCRYPTION_KEY` itself out of `docker inspect`.
