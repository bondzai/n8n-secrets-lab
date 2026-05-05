# n8n Secrets Lab — driver
# Usage:
#   make up DEMO=1        # start demo 1
#   make attack DEMO=1    # run leak demonstration
#   make smoke DEMO=1     # open browser
#   make logs DEMO=1      # tail n8n logs
#   make down DEMO=1      # stop + delete volumes for demo 1
#   make ps               # show all lab containers
#   make nuke             # tear down every demo
#   make help             # this menu

DEMO ?= 1

# Map DEMO=1..4 to its folder name
DIR_1 := 01-dotenv-plaintext
DIR_2 := 02-n8n-credentials
DIR_3 := 03-docker-secrets
DIR_4 := 04-infisical
DIR := $(DIR_$(DEMO))

# n8n container name pattern (compose v2: <project>-<service>-1)
N8N := $(DIR)-n8n-1
PG  := $(DIR)-postgres-1

.PHONY: help up down logs attack smoke ps nuke prep-2 prep-3 _check wait seed up-4a up-4b

# Default owner credentials (auto-seeded after boot)
OWNER_EMAIL    := admin@local.test
OWNER_PASSWORD := Demo1234!
OWNER_FIRST    := Demo
OWNER_LAST     := Owner

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Set DEMO=1|2|3|4 (default 1). Examples:"
	@echo "  make up DEMO=2 && make attack DEMO=2 && make smoke DEMO=2"

_check:
	@test -n "$(DIR)" || (echo "Unknown DEMO=$(DEMO). Use 1, 2, 3, or 4."; exit 1)

# ---- per-demo prep (generate keys / scaffolding) ----

prep-2: ## Generate N8N_ENCRYPTION_KEY for demo 2
	@printf "N8N_ENCRYPTION_KEY=%s\n" "$$(openssl rand -hex 32)" > $(DIR_2)/.env
	@echo "wrote $(DIR_2)/.env with a fresh 32-byte hex key"

prep-3: ## Generate encryption key file for demo 3
	@openssl rand -hex 32 | tr -d '\n' > $(DIR_3)/secrets/n8n_encryption_key.txt
	@chmod 600 $(DIR_3)/secrets/n8n_encryption_key.txt
	@echo "wrote $(DIR_3)/secrets/n8n_encryption_key.txt (chmod 600)"

# ---- lifecycle ----

up: _check ## Start demo (DEMO=N)
	@if [ "$(DEMO)" = "2" ] && [ ! -s "$(DIR_2)/.env" -o "$$(grep -c replace_me $(DIR_2)/.env)" != "0" ]; then \
	  $(MAKE) prep-2; fi
	@if [ "$(DEMO)" = "3" ] && grep -q replace_with $(DIR_3)/secrets/n8n_encryption_key.txt 2>/dev/null; then \
	  $(MAKE) prep-3; fi
	cd $(DIR) && docker compose up -d
	@$(MAKE) wait DEMO=$(DEMO) --no-print-directory
	@$(MAKE) seed DEMO=$(DEMO) --no-print-directory
	@echo ""
	@echo "▶ n8n:       http://localhost:5678"
	@echo "▶ login:     $(OWNER_EMAIL) / $(OWNER_PASSWORD)"
	@if [ "$(DEMO)" = "4" ]; then echo "▶ infisical: http://localhost:8080"; fi
	@echo "▶ next:      make attack DEMO=$(DEMO)  |  make smoke DEMO=$(DEMO)"

seed: _check ## Auto-create owner account so you skip the setup screen
	@printf "waiting for /rest routes"; \
	for i in $$(seq 1 30); do \
	  probe=$$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" \
	    -X POST http://localhost:5678/rest/owner/setup \
	    -H "Content-Type: application/json" -d '{}'); \
	  if [ "$$probe" = "400" ] || [ "$$probe" = "200" ]; then echo " ✓"; break; fi; \
	  printf "."; sleep 1; \
	done; \
	response=$$(/usr/bin/curl -s -o /tmp/n8n_seed.out -w "%{http_code}" \
	  -X POST http://localhost:5678/rest/owner/setup \
	  -H "Content-Type: application/json" \
	  -d '{"email":"$(OWNER_EMAIL)","firstName":"$(OWNER_FIRST)","lastName":"$(OWNER_LAST)","password":"$(OWNER_PASSWORD)"}'); \
	case "$$response" in \
	  200|201) echo "owner seeded → $(OWNER_EMAIL) / $(OWNER_PASSWORD)" ;; \
	  400)     msg=$$(cat /tmp/n8n_seed.out); \
	           case "$$msg" in *"already"*|*"setup"*) echo "owner already exists — skipping" ;; \
	             *) echo "seed 400: $$msg" ;; esac ;; \
	  *)       echo "seed failed (HTTP $$response): $$(cat /tmp/n8n_seed.out)" ;; \
	esac

wait: _check ## Wait until n8n responds on :5678
	@printf "waiting for n8n"
	@for i in $$(seq 1 60); do \
	  if curl -sf -o /dev/null http://localhost:5678/healthz 2>/dev/null \
	     || curl -sf -o /dev/null http://localhost:5678 2>/dev/null; then \
	    echo " ✓ ready"; exit 0; \
	  fi; \
	  printf "."; sleep 2; \
	done; \
	echo " ✗ timed out"; exit 1

down: _check ## Stop demo + delete volumes (DEMO=N)
	cd $(DIR) && docker compose down -v

logs: _check ## Tail n8n logs (DEMO=N)
	cd $(DIR) && docker compose logs -f n8n

ps: ## Show all lab containers
	@docker ps --filter "name=0[1-4]-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

up-4a: ## Demo 4 phase A — bring up only Infisical for one-time bootstrap
	cd $(DIR_4) && docker compose up -d infisical-db infisical-redis infisical
	@printf "waiting for infisical"; \
	for i in $$(seq 1 60); do \
	  if /usr/bin/curl -sf -o /dev/null http://localhost:8080/api/status 2>/dev/null \
	     || /usr/bin/curl -sf -o /dev/null http://localhost:8080 2>/dev/null; then \
	    echo " ✓ ready"; break; \
	  fi; printf "."; sleep 2; \
	done
	@echo ""
	@echo "▶ Open http://localhost:8080 and complete bootstrap (see ATTACK.md step 2)"
	@echo "▶ When done filling .env, run:  make up-4b"

up-4b: ## Demo 4 phase B — bring up sidecar + n8n once .env is filled
	@test -s $(DIR_4)/.env || (echo "$(DIR_4)/.env missing — copy .env.example and fill it"; exit 1)
	cd $(DIR_4) && docker compose up -d
	@$(MAKE) wait DEMO=4 --no-print-directory
	@$(MAKE) seed DEMO=4 --no-print-directory
	@echo ""
	@echo "▶ n8n:       http://localhost:5678   ($(OWNER_EMAIL) / $(OWNER_PASSWORD))"
	@echo "▶ infisical: http://localhost:8080"

nuke: ## Tear down every demo
	-cd $(DIR_1) && docker compose down -v 2>/dev/null
	-cd $(DIR_2) && docker compose down -v 2>/dev/null
	-cd $(DIR_3) && docker compose down -v 2>/dev/null
	-cd $(DIR_4) && docker compose down -v 2>/dev/null
	@echo "all demos torn down"

smoke: _check ## Open n8n in default browser (DEMO=N)
	@open http://localhost:5678 2>/dev/null || xdg-open http://localhost:5678 2>/dev/null || echo "open http://localhost:5678 manually"

# ---- the interesting part: attack scripts per demo ----

attack: _check ## Run the leak demonstration for this demo
	@echo ""
	@echo "═══════════════════════════════════════════════════════════"
	@echo " ATTACK SURFACE — Demo $(DEMO) ($(DIR))"
	@echo "═══════════════════════════════════════════════════════════"
	@$(MAKE) attack-$(DEMO) --no-print-directory

attack-1:
	@echo ""
	@echo "▼ LEAK 1 — file on host disk"
	@cat $(DIR_1)/.env
	@echo ""
	@echo "▼ LEAK 2 — docker inspect (no shell needed)"
	@docker inspect $(N8N) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i demo || echo "(not running)"
	@echo ""
	@echo "▼ LEAK 3 — printenv inside the container"
	@docker exec $(N8N) printenv DEMO_API_KEY 2>/dev/null || echo "(not running)"
	@echo ""
	@echo "▼ LEAK 4 — /proc/1/environ"
	@docker exec $(N8N) sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep DEMO' 2>/dev/null || echo "(not running)"
	@echo ""
	@echo "VERDICT: secret is in 4 different places. Plaintext everywhere."

attack-2:
	@echo ""
	@echo "▼ CHECK 1 — DEMO_API_KEY is NOT in env (we never put it there)"
	@docker exec $(N8N) printenv | grep -i demo || echo "  ✓ clean — no DEMO_* in env"
	@echo ""
	@echo "▼ CHECK 2 — DEMO_API_KEY is NOT in docker inspect"
	@docker inspect $(N8N) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i demo || echo "  ✓ clean"
	@echo ""
	@echo "▼ EXPOSURE — encrypted blob in Postgres credentials_entity"
	@docker exec $(PG) psql -U n8n -d n8n -c "SELECT name, type, LEFT(data::text, 80) AS data_preview FROM credentials_entity;" 2>/dev/null \
	  || echo "  (no credentials yet — create one in the n8n UI then re-run)"
	@echo ""
	@echo "▼ THE WEAK LINK — the encryption key IS in env"
	@docker exec $(N8N) printenv N8N_ENCRYPTION_KEY
	@echo ""
	@echo "VERDICT: API key encrypted at rest, but DB dump + the key above = full compromise."

attack-3:
	@echo ""
	@echo "▼ CHECK 1 — N8N_ENCRYPTION_KEY itself is OFF env now"
	@docker exec $(N8N) printenv | grep -i encryption || echo "  (only the _FILE pointer)"
	@echo ""
	@echo "▼ CHECK 2 — docker inspect shows only the path, not the value"
	@docker inspect $(N8N) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -i encryption
	@echo ""
	@echo "▼ EXPOSURE — value lives on tmpfs, only readable inside container"
	@docker exec $(N8N) ls -la /run/secrets/
	@docker exec $(N8N) cat /run/secrets/n8n_encryption_key
	@echo ""
	@echo "VERDICT: secret off env / off docker-inspect. Container shell still wins."

attack-4:
	@echo ""
	@echo "▼ CHECK 1 — n8n env is CLEAN of business secrets at rest"
	@docker inspect $(N8N) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE 'demo|encryption' || echo "  ✓ nothing"
	@echo ""
	@echo "▼ EXPOSURE — fetched secrets live on tmpfs from the sidecar"
	@docker exec $(N8N) cat /run/secrets-shared/secrets.env 2>/dev/null || echo "  (sidecar not ready yet)"
	@echo ""
	@echo "▼ ROTATION — change a value in Infisical UI, sidecar re-fetches every 5min"
	@echo "▼ AUDIT    — http://localhost:8080 → Audit Logs"
	@echo ""
	@echo "VERDICT: secret manager owns the secret. n8n holds only a short-lived copy."
