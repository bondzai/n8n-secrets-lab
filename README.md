# n8n Secrets Lab

Four runnable Docker demos that store the **same** API key in four different ways,
so you can see exactly what an attacker reaches in each case.

> The point isn't the n8n workflow. It's **where the secret lives** and
> **what is needed to steal it.**

```
        DEMO 1 ───▶ DEMO 2 ───▶ DEMO 3 ───▶ DEMO 4
       plaintext   encrypted   key off env  external
        in env     in DB       (file mount) secret mgr
          │           │            │            │
          ▼           ▼            ▼            ▼
   docker       DB dump +    container     audit-logged
   socket       env key      shell only    + rotatable
```

Each step **shrinks the blast radius** at the cost of a little more setup.

---

## TL;DR — the trade-off matrix

| | 1. `.env` plaintext | 2. n8n credentials | 3. Docker secrets | 4. Infisical |
|---|:---:|:---:|:---:|:---:|
| Setup effort | 🟢 trivial | 🟢 one env var | 🟡 file + compose | 🔴 service + bootstrap |
| Secret in `docker inspect` | ❌ yes | ⚠️ encryption key only | ✅ no | ✅ no |
| Secret in `printenv` | ❌ yes | ⚠️ encryption key only | ✅ no | ⚠️ at runtime, sourced from tmpfs |
| Secret on host disk | ❌ plaintext | ⚠️ encryption key in `.env` | ⚠️ key file (chmod 600) | ✅ no business secret on host |
| Workflow author can `$env.X` | ❌ yes (with flag) | ✅ no | ✅ no | depends on usage |
| Encrypted at rest in DB | ❌ no | ✅ yes | ✅ yes | ✅ yes |
| Rotation w/o redeploy | ❌ no | ❌ no (re-encrypt all) | ❌ no (rewrite + restart) | ✅ yes (auto re-fetch) |
| Audit log of secret access | ❌ no | ❌ no | ❌ no | ✅ yes |
| Single point of compromise | host disk | host disk + DB | container shell | Machine Identity creds |
| Maps to GCP prod | ❌ never | ✅ key from Secret Manager | ✅ key from CSI mount | ✅ same pattern, swap to GCP SM |

**Verdict**: Demo 2 is the minimum acceptable baseline. Demo 3 is the highest
return-on-effort upgrade. Demo 4 is the only one that solves rotation + audit.

---

## How to run

```bash
make help                      # menu
make up DEMO=1                 # boot, wait, auto-seed owner
make smoke DEMO=1              # open browser
make attack DEMO=1             # show what attacker sees
make down DEMO=1               # tear down + delete volumes
make ps                        # what's running
make nuke                      # tear down everything

# Demo 4 has a one-time UI bootstrap, so it's split:
make up-4a                     # boots Infisical only → click through UI → fill .env
make up-4b                     # boots sidecar + n8n once .env is filled
```

Default n8n login (auto-seeded by `make up`):
**`admin@local.test` / `Demo1234!`**

---

## Test results — what we actually observed

The same API key (`sk_demo_SUPER_SECRET_12345`) was stored four different ways
and an attacker tried to extract it through `docker inspect`, `printenv`,
`/proc`, the Postgres dump, and the host filesystem. Here is what each demo
gave up.

### Demo 1 — `.env` plaintext (the antipattern)

Secret leaked in **4 different places**:

```
▼ LEAK 1 — file on host disk
DEMO_API_KEY=sk_demo_SUPER_SECRET_12345

▼ LEAK 2 — docker inspect (no shell needed)
DEMO_API_KEY=sk_demo_SUPER_SECRET_12345

▼ LEAK 3 — printenv inside the container
sk_demo_SUPER_SECRET_12345

▼ LEAK 4 — /proc/1/environ (any process with same uid)
DEMO_API_KEY=sk_demo_SUPER_SECRET_12345
```

**Why this is bad**: `docker inspect` is the killer. Anyone in the `docker`
group, any monitoring sidecar, any CI step that prints container metadata
sees the key. **No shell needed.**

---

### Demo 2 — n8n native credentials (encrypted in Postgres)

Same attack, much smaller surface:

```
▼ DEMO_API_KEY in env?           ✓ clean
▼ DEMO_API_KEY in docker inspect? ✓ clean
▼ Encrypted blob in Postgres:
   name   |      type      |                  data_preview
----------+----------------+--------------------------------------------------
 demo-key | httpHeaderAuth | U2FsdGVkX19KWdHImCh44ddZLDMGi7/rR9GFtfLnAZCAkzwL
                            ↑ AES-256-CBC ciphertext (Salted__ prefix)
```

But the encryption key itself is still in env:

```
▼ THE WEAK LINK — N8N_ENCRYPTION_KEY:
f75f6b12e9d586b813bc0c9e73024894acb6307986b67302995516e574b71112
```

**Proof of compromise** (the textbook attack chain):

```bash
# Step 1: steal the key from env (no container shell needed)
KEY=$(docker exec ... printenv N8N_ENCRYPTION_KEY)

# Step 2: dump the credential blob from DB
CT=$(psql ... -c "SELECT data FROM credentials_entity ...")

# Step 3: decrypt offline
echo "$CT" | openssl enc -aes-256-cbc -d -a -md md5 -pass pass:$KEY
# → {"name":"X-Api-Key","value":"sk_demo_SUPER_SECRET_12345"}    ❌ pwned
```

**Lesson**: encryption is only as good as the separation between the key and
the ciphertext. Co-located = useless.

---

### Demo 3 — Docker Secrets (key off env, into tmpfs file)

Same setup as Demo 2 but `N8N_ENCRYPTION_KEY` is loaded via the `_FILE`
suffix from a tmpfs mount (Compose `secrets:` block).

| Attack step | Demo 2 | Demo 3 |
|---|---|---|
| `printenv N8N_ENCRYPTION_KEY` | leaked | **empty** (exit 1) |
| `docker inspect` env list | leaked | only path `/run/secrets/...` |
| Decrypt the blob | works | works (after shell access) |

Observed:

```
▼ printenv N8N_ENCRYPTION_KEY → exit=1   (not in env)
▼ docker inspect            → only N8N_ENCRYPTION_KEY_FILE=/run/secrets/...
▼ key obtained via shell    → docker exec ... cat /run/secrets/n8n_encryption_key
   f0e38419ed02445731a6b9b52ef50cfc4d7b42b67d318cc99d43f2136a0ecd6a
▼ decrypt with stolen key   → {"name":"X-Api-Key","value":"sk_demo_SUPER_SECRET_12345"}
```

**What changed**: the attack now requires **shell access to the container**
(`docker exec`), not just docker socket / inspect privilege. This eliminates:

- Monitoring agents that scrape container metadata
- `docker compose config` / log bundles / support exports
- Sibling-container attacks via shared PID namespace (`/proc/*/environ`)

Cheapest meaningful upgrade in the lab — **zero new infrastructure**.

---

### Demo 4 — Infisical (external secret manager)

Architecture:

```
You ─UI─▶ Infisical ──── stores secrets, issues Machine Identity credentials
                │
                ▼
   infisical-agent (sidecar)
        │ login with CLIENT_ID/SECRET (the only on-disk secret)
        │ infisical export → /shared/secrets.env  (tmpfs)
        │ re-fetch every 5 min
        ▼
   n8n ── sources /shared/secrets.env at boot
```

What an attacker now sees:

| Vector | Result |
|---|---|
| `docker inspect` n8n env | clean — only DB connection vars |
| Host filesystem `.env` | only `INFISICAL_CLIENT_ID/SECRET` (revocable, audit-logged) |
| Container shell `cat /run/secrets-shared/secrets.env` | reads sourced secrets — same as demo 3, container shell still wins |
| **New capability: rotation** | change value in Infisical UI → sidecar re-fetches in ≤5 min → no n8n redeploy |
| **New capability: audit** | Infisical UI → Audit Logs shows which Machine Identity fetched which secret when |

**The "secret zero" tradeoff**: you have to put *something* in `.env` to
authenticate against Infisical. The win: that something is short-lived,
scoped (Viewer on one env), revocable, and every use is logged. Compare
that with Demo 1 where the secret itself is the credential.

---

## What this demo does **not** cover

- **Demo 5 (n8n Enterprise External Secrets)** — skipped because the lab uses
  Community Edition. In Enterprise, n8n natively resolves `{{ $secrets.vault.X }}`
  inside workflows so even the `credentials_entity` table never holds the
  business secret.
- **Network-level secret protection** — TLS to Infisical, Postgres SSL,
  network policies. The lab keeps everything on a Docker bridge for clarity.
- **HSM / KMS-backed envelope encryption** — the next step beyond Demo 4
  for regulated workloads.

---

## Mapping to production (GCP)

Same demos translated:

| Local | Production on GCP |
|---|---|
| Demo 1 | ❌ never |
| Demo 2 (key in `.env`) | Key from **GCP Secret Manager** → injected via env at boot |
| Demo 3 (key in tmpfs file) | **GCP Secret Manager CSI driver** mounts secret as a file in GKE |
| Demo 4 (Infisical sidecar) | **Same pattern, swap Infisical → GCP Secret Manager**: sidecar uses `gcloud secrets versions access`; auth via Workload Identity (no `CLIENT_SECRET` on disk at all) |

The Demo 4 architecture is what carries over to prod. Infisical is the
training-wheels version of the GCP Secret Manager pattern.

---

## Files

```
n8n-secrets-lab/
├── README.md                  ← you are here
├── Makefile                   ← lifecycle driver
├── 00-shared/
│   └── workflow.json          ← optional importable demo workflow
├── 01-dotenv-plaintext/
│   ├── docker-compose.yml
│   └── ATTACK.md              ← per-demo leak reproduction
├── 02-n8n-credentials/
│   ├── docker-compose.yml
│   └── ATTACK.md
├── 03-docker-secrets/
│   ├── docker-compose.yml
│   ├── secrets/               ← key file, gitignored
│   └── ATTACK.md
└── 04-infisical/
    ├── docker-compose.yml
    ├── .env.example
    └── ATTACK.md
```

Each `ATTACK.md` has copy-pasteable commands so you can re-run the
verification on your own host.
