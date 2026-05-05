# Demo 3 — Docker Secrets (file mount, not env)

## Setup
```bash
openssl rand -hex 32 | tr -d '\n' > secrets/n8n_encryption_key.txt
chmod 600 secrets/n8n_encryption_key.txt
docker compose up -d
```

n8n reads `N8N_ENCRYPTION_KEY_FILE` and loads the value from
`/run/secrets/n8n_encryption_key` (a tmpfs mount inside the container).

## Reproduce — what changed vs Demo 2

```bash
# Win: the key is NOT in env anymore
docker exec 03-docker-secrets-n8n-1 printenv | grep -i encryption
# → only N8N_ENCRYPTION_KEY_FILE=/run/secrets/...   (the path, not the value)

# Win: NOT in docker inspect either
docker inspect 03-docker-secrets-n8n-1 | grep -i encryption
# → only the file path

# Remaining loss: anyone with shell in the container still reads it
docker exec 03-docker-secrets-n8n-1 cat /run/secrets/n8n_encryption_key

# Remaining loss: anyone with host root reads the source file
sudo cat ./secrets/n8n_encryption_key.txt
```

## Trade-off

| Pro | Con |
|-----|-----|
| Secret is **off env** — `docker inspect`, monitoring agents, `/proc/*/environ` all clean | Source file still plaintext on the host |
| Mounted as tmpfs (RAM, not disk) inside container | Container shell access still wins |
| Simple — pure Docker, no extra service | Rotation = rewrite file + restart container |
| Compose `secrets:` is portable to Swarm where it becomes a real encrypted secret | No audit log |

## Verdict
A meaningful step up from Demo 2 with **zero new infrastructure**. Good for
single-host prod when you don't (yet) want a secret manager. But it does not
solve rotation or auditing.
