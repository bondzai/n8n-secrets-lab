# Demo 1 — `.env` plaintext (the baseline / antipattern)

## Where the secret lives
- On disk: `./.env` (plaintext, world-readable if perms loose)
- In the container: as an **environment variable** on PID 1
- In Docker metadata: visible via `docker inspect`

## Reproduce the leaks

```bash
docker compose up -d

# Leak 1: file on disk
cat .env

# Leak 2: docker metadata (no shell access needed, only docker socket)
docker inspect 01-dotenv-plaintext-n8n-1 | grep -A1 DEMO_API_KEY

# Leak 3: any process inside the container sees it
docker exec 01-dotenv-plaintext-n8n-1 printenv DEMO_API_KEY

# Leak 4: /proc exposes env to anyone with the same uid in the container
docker exec 01-dotenv-plaintext-n8n-1 sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep DEMO'
```

## Trade-off

| Pro | Con |
|-----|-----|
| Zero setup | Plaintext on host disk |
| Works with every tool | Easy to `git add` by accident |
| | `docker inspect` exposes it (CI logs, monitoring agents, anyone with docker group) |
| | No rotation without container restart |
| | No audit — you cannot tell who read it |

## Verdict
Local prototyping only. **Never** in shared environments, **never** in CI, **never** in prod.
