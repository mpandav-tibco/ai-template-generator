# BWCE AI Generator — Demo Script (UI → Runtime)

A tight ~7-minute walkthrough of the solution we built: the web UI, the **REST APIs**, the governance
guardrails, and the live runtime side-effects.

> Slides: [`demo/demo-slides.md`](demo-slides.md) · Automated CLI tour: [`demo/run-demo.sh`](run-demo.sh)

---

## 0 · Setup (once, before the room is watching)

```bash
# Brings up Postgres, Weaviate, MailDev, Ollama + builds/starts the app
./demo/start-demo.sh --build        # drop --build on later runs

# Sanity: API is up
curl -s localhost:9999/health
```

Open two browser tabs: **http://localhost:9999/** (chat UI) · **http://localhost:9999/docs** (API ref) — plus **http://localhost:1080** (MailDev inbox) for the side-effect proof.

> **Reset between dry-runs:** `docker exec flogo-studio-postgres psql -U flogo -d flogo_agent_studio -c 'TRUNCATE generation_log;'`

---

## 1 · The Web UI — conversational generation  *(UI layer)*

Open **http://localhost:9999/** — the chat greets you with *"Hello! Describe the integration you need."*
The page has: a message box, **Send**, a live **spec card**, a **Generate Repository** button (greyed out until the spec is valid), and **↻ New conversation**.

Drive it with one of the two paths below (type the line **verbatim**, press **Send**):

**▶ Path A — one sentence (fastest).** Type:
```
publish sales order from s4hana to kafka using template S4HANA_PUB_To_KAFKATopic, email core-integration@adidas.com, scenario 1234, PROD
```
→ the spec card fills (S4HANA→KAFKA, sales order, pub, scenario 1234, PROD), the bot replies
*"All required fields collected — ready to generate!"*, and **Generate Repository** turns active.
**Say:** "One plain-English sentence → a complete, valid spec. No forms, no template lookup."

**▶ Path B — multi-turn (shows the intelligence).**
1. Type: `publish sales order from s4hana to kafka, scenario 1234, PROD, CDM required`
   → bot asks *"Which template should we use? (e.g. S4HANA_PUB_To_KAFKATopic_CDM)"* — **Generate stays greyed out** (missing `template_type`).
2. Type: `use template S4HANA_PUB_To_KAFKATopic and email core-integration@adidas.com`
   → bot: *"All required fields collected — ready to generate!"* — **Generate Repository** unlocks.
**Say:** "Multi-turn — it remembers the session (**persisted in PostgreSQL `chat_session`**, survives a reload) and only unlocks Generate when the spec is valid."

**Step — Click `Generate Repository`.** The result box shows **✓ Repository generated**, the `repo_name`
(`s4hana-sales-order-kafka-pub`), the generation id, and the git clone command.
**Say:** "That one click ran the whole pipeline — IKD check, template RAG, registry insert, scaffold, email."

**Step — Show idempotency in the UI.** Click **↻ New conversation**, repeat the same description, click
**Generate Repository** again → the result turns amber: *"This repository already exists."*
**Say:** "Re-submitting the same request is caught — no duplicate repo."

**Then:** open **http://localhost:9999/docs** — the live OpenAPI reference with *Try-it*.
**Say:** "Same engine is a documented REST API — any portal or pipeline can drive it."

---

## 2 · One-shot NLU extraction  *(REST · understanding)*

```bash
curl -s -X POST localhost:9999/extract -H 'Content-Type: application/json' \
  -d '{"message":"publish sales order from s4hana to kafka, scenario 1234, PROD, CDM required"}' | python3 -m json.tool
```

**Say:** "A deterministic YAML **rule engine** pulls high-confidence signals first; a local **Ollama**
LLM fills the rest. LLM output wrapped in prose or ```code fences``` is sanitized before parsing —
so small local models are reliable."

---

## 3 · The generate pipeline + governance  *(REST · the headline flow)*

**3a — Happy path:**
```bash
curl -s -X POST localhost:9999/generate -H 'Content-Type: application/json' \
  -d '{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"sales-order-demo","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"core-integration@adidas.com"}}' | python3 -m json.tool
```
**Say:** "Validate → IKD cross-check → **template RAG (Weaviate)** → register (PostgreSQL) → scaffold repo → email."

**3b — Idempotency (re-run the exact same command):** returns the existing record, does **not** re-scaffold.
**Say:** "Duplicate specs are caught — no accidental repos."

**3c — Guardrail (unknown IKD id):**
```bash
curl -s -X POST localhost:9999/generate -H 'Content-Type: application/json' \
  -d '{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"order","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"d@adidas.com","interface_id":"IKD-DOESNOTEXIST"}}' | python3 -m json.tool
```
**Say:** "An IKD id outside the registry is rejected **before any side effect**."

**3d — Race-safe (optional, impressive):**
```bash
for i in 1 2 3 4 5; do curl -s -X POST localhost:9999/generate -H 'Content-Type: application/json' \
  -d '{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"race-demo","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"d@adidas.com"}}' -o /dev/null & done; wait
docker exec flogo-studio-postgres psql -U flogo -d flogo_agent_studio -t -c "SELECT count(*) FROM generation_log WHERE repo_name='s4hana-race-demo-kafka-pub';"
```
**Say:** "Five concurrent identical requests → **exactly one** row. A unique index + `ON CONFLICT` makes it safe under load."

**3e — Config-only refresh** (re-emit pipeline/Dockerfile/k8s only, no repo, bypasses dup):
```bash
curl -s -X POST localhost:9999/generate -H 'Content-Type: application/json' \
  -d '{"config_only":true,"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"sales-order-demo","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"d@adidas.com"}}' | python3 -m json.tool
```
**Say:** "Config-only mode refreshes just the 3 config files for an existing repo — no re-scaffold, no duplicate."

**3f — Bad input → clean 400** (not a 500): `-d '{"spec":{"source_system":"s4hana"}}'` returns **400 VALIDATION_ERROR**.
**Say:** "Missing fields fail fast with a 400 — the API boundary is hardened, errors don't leak."

---

## 4 · Proof of the live side-effects  *(runtime layer)*

```bash
# PostgreSQL generation registry
docker exec flogo-studio-postgres psql -U flogo -d flogo_agent_studio \
  -c "SELECT repo_name,status,template_type,created_at FROM generation_log ORDER BY created_at DESC LIMIT 5;"

# Scaffolded repository on disk (Dockerfile, k8s, README, manifest.json, pipeline)
find generated-repos -maxdepth 2 -type f | tail -10
```
**Then:** open **http://localhost:1080** — show the notification email: **HTML body + inline brand logo + manifest attachment + emoji subject** (config-only sends a refresh-styled variant).

**Say:** "Real, verifiable outputs: a governed DB record (with cdm / need_secret / country / unique_id), a
production-shaped repo on disk, and a rich notification email — all driven by the one sentence we started with."

---

## 5 · Under the hood — 100% Flogo-native  *(design → runtime)*

**Show:** open `bwce-ai-generator.flogo` in the Flogo VS Code editor → the `generate_POST` flow graph.

**Say:**
- "One Flogo app, one binary serves the REST APIs (`:9999`)."
- "The pipeline is visual: `#ruleengine` (deterministic pre-extract) → `#ragQuery` (Weaviate vector search **+** Ollama LLM in one step) → `#query`/`#insert` (PostgreSQL) → scaffold & email subflows."
- "No bespoke microservice, no orchestration layer — the agentic logic *is* the integration app."

---

## Close (30s)

**Delivered:** conversational + one-shot extraction · template RAG · IKD governance · idempotent,
race-safe generation · repo scaffolding · notifications — all on **TIBCO Flogo Agentic AI**, over clean **REST APIs**.

**Bonus (not demoed):** the same capabilities are also exposed over an **MCP server**, so Claude/Copilot
agents can drive them as native tools — extra value, no extra code. *(Show on request: `./demo/mcp-demo.sh`.)*

**Next:** wire scaffolding to real Bitbucket/Git creation · expand the template & IKD catalog · add
CI hooks/approvals · promote local Ollama to the platform LLM endpoint.

---

### One-glance command cheat-sheet

| Layer | Command |
|-------|---------|
| Start | `./demo/start-demo.sh --build` |
| UI | open `http://localhost:9999/` and `…/docs` |
| Extract | `curl -s -X POST localhost:9999/extract -d '{"message":"…"}'` |
| Generate | `curl -s -X POST localhost:9999/generate -d '{"spec":{…}}'` |
| Config-only | add `"config_only":true` → refreshes 3 files, no repo, dup-safe |
| Race-safe | 6× same spec → 1 DB row · bad input → 400 (not 500) |
| Proof | `psql … generation_log` · `find generated-repos` · `http://localhost:1080` |
| Automated tour | `./demo/run-demo.sh` (REST + runtime, hands-free with `--auto`) |
| Reset | `… psql … -c 'TRUNCATE generation_log;'` |
