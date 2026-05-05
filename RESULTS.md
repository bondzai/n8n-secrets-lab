# Results Summary — n8n Secrets Lab

Presentation-ready summary of the four storage methods, tested locally on
Docker Desktop with `n8nio/n8n:2.18.7`, `postgres:16`, `infisical:latest`.

Same fake API key (`sk_demo_SUPER_SECRET_12345`) stored four ways. Same
attack toolkit (`docker inspect`, `printenv`, `psql`, `openssl`).

---

## 1. Attack surface comparison

✅ = clean   ⚠️ = partial exposure   ❌ = leaked plaintext

| Attack vector | Demo 1<br>`.env` | Demo 2<br>n8n creds | Demo 3<br>docker secrets | Demo 4<br>Infisical |
|---|:---:|:---:|:---:|:---:|
| `cat .env` (host file) | ❌ | ⚠️ key only | ⚠️ key file | ⚠️ MI creds only |
| `docker inspect` env | ❌ | ⚠️ key only | ✅ | ✅ |
| `docker exec printenv` | ❌ | ⚠️ key only | ✅ | ⚠️ at runtime |
| `/proc/1/environ` | ❌ | ⚠️ key only | ✅ | ⚠️ at runtime |
| Postgres `credentials_entity` | n/a | 🔒 ciphertext | 🔒 ciphertext | 🔒 ciphertext |
| `$env.X` from workflow | ❌ | ✅ | ✅ | ✅ |
| Sibling container shared PID | ❌ | ⚠️ | ✅ | ✅ |

---

## 2. Capability comparison

| Capability | Demo 1 | Demo 2 | Demo 3 | Demo 4 |
|---|:---:|:---:|:---:|:---:|
| Encrypted at rest | ❌ | ✅ | ✅ | ✅ |
| Key separated from ciphertext | ❌ | ❌ | ⚠️ same host | ✅ different system |
| Rotation w/o redeploy | ❌ | ❌ | ❌ | ✅ |
| Audit log of secret access | ❌ | ❌ | ❌ | ✅ |
| Per-secret RBAC | ❌ | ✅ in-app | ❌ | ✅ |
| Works with all n8n nodes | ❌* | ✅ | ✅ | ✅ |
| Bootstrap complexity | trivial | trivial | low | medium |

*Demo 1 requires `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` to be useful, which itself
weakens the platform.

---

## 3. Attacker effort to recover plaintext

| What attacker needs | Demo 1 | Demo 2 | Demo 3 | Demo 4 |
|---|:---:|:---:|:---:|:---:|
| Access to docker socket | ✓ enough | ✗ need DB too | ✗ need shell | ✗ need MI creds |
| Access to host filesystem | ✓ enough | ✗ need DB too | ✓ enough | ✗ need MI creds |
| Container shell (`docker exec`) | ✓ enough | ✓ enough | ✓ enough | ✓ enough |
| **Lowest privilege that wins** | docker socket | docker socket | container shell | MI creds + audit trail |

**Translation**: Demo 1's keys leak to anyone with `docker ps` permission.
Demo 4's keys require a *named, revocable, logged* identity to access.

---

## 4. Verified vs architectural

| Demo | Status |
|---|---|
| 1 | ✅ Verified — 4 leak vectors confirmed (see screenshots/transcript) |
| 2 | ✅ Verified — encrypted blob in DB, full attack chain decrypted plaintext |
| 3 | ✅ Verified — env clean, key only via `docker exec cat /run/secrets/...` |
| 4 | ⚠️ Partial — Infisical bootstrap automation hit API-shape friction; architecture validated, end-to-end attack run pending UI bootstrap |

---

## 5. Recommendation matrix

| Context | Use |
|---|---|
| Local prototyping, single dev | Demo 2 (n8n native, plain `.env` for the key) |
| Small team, single VPS | Demo 3 (docker secrets for the encryption key) |
| Multi-env, rotation needed, audit needed | Demo 4 (external secret manager) |
| GCP production target | Demo 4 pattern, swap Infisical → **GCP Secret Manager** |
| Regulated / compliance | Demo 4 + KMS-backed envelope encryption + n8n Enterprise External Secrets |

---

## 6. Decision drivers (for the team)

1. **Do we need rotation without redeploy?** → Demo 4 only.
2. **Do we need an audit log of secret access?** → Demo 4 only.
3. **Are we OK operating one extra service?** → If no, Demo 3 is the ceiling.
4. **Will this codebase be open-sourced or shared widely?** → Demo 1 is unsafe regardless of `.gitignore`; one merge mistake leaks forever.
5. **Are non-admins authoring workflows?** → Demo 2+ keep secrets out of `$env.X` reach.

---

## 7. Cost of moving up the ladder

| Move | New ops cost | New skill required |
|---|---|---|
| 1 → 2 | ~0 (one env var) | none |
| 2 → 3 | ~0 (one compose block) | understand `_FILE` suffix convention |
| 3 → 4 | one extra service + DB | secret manager admin + Machine Identity model |
| Local 4 → GCP SM | swap sidecar binary | GCP IAM, Workload Identity |

Each step is ~constant effort. There's no "scary" jump — picking #4 from day one
is reasonable if you know you'll need rotation + audit eventually.

---

## 8. Next actions

- [ ] Finish Demo 4 end-to-end run, capture observed `make attack DEMO=4` output
- [ ] Write GCP Secret Manager variant (`05-gcp-sm/`) using the same sidecar pattern
- [ ] Document credential rotation procedure for whichever method we adopt
- [ ] Pick a method and migrate existing n8n credentials
