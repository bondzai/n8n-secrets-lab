# n8n Secrets Lab

Four runnable demos, each storing the **same** API key in a different way.
The point is not the n8n workflow — it is **where the secret lives** and **what an attacker can see** at each step.

## The progression

| # | Folder | Pattern | Visible to attacker who has... |
|---|--------|---------|-------------------------------|
| 1 | `01-dotenv-plaintext` | `.env` mounted as env vars | repo access · `docker inspect` · host shell |
| 2 | `02-n8n-credentials` | n8n native credentials, encrypted in Postgres | DB dump **+** `N8N_ENCRYPTION_KEY` |
| 3 | `03-docker-secrets`   | Compose `secrets:` → tmpfs file mount | container shell only (not env, not inspect) |
| 4 | `04-infisical`        | External secret manager, fetched at runtime | manager token only · audit-logged · rotatable |

## How to run each demo

```bash
cd 0X-...
docker compose up -d
# follow ATTACK.md to see the leak surface
docker compose down -v
```

All demos use:
- `n8nio/n8n:latest`
- `postgres:16` (seeded fresh each run; no Supabase yet)
- The fake API key value: `sk_demo_SUPER_SECRET_12345`

## Mapping to GCP production

| Local (this lab) | GCP equivalent |
|------------------|----------------|
| `.env` file | ❌ never |
| `N8N_ENCRYPTION_KEY` in env | Secret Manager → injected at boot |
| Compose `secrets:` | Secret Manager CSI driver / file mount |
| Infisical container | **GCP Secret Manager** (same fetch-at-runtime pattern) |

When you move to prod, demo #4 is the one that survives — swap Infisical for GCP Secret Manager, keep the architecture.
