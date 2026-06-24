#!/usr/bin/env bash
# ============================================================================
# BWCE AI Generator — Guided Demo Walkthrough
# ----------------------------------------------------------------------------
# A paced, narrated tour of the solution that hits every key capability:
#
#   1. Health & template catalog           (app + VectorDB ingestion)
#   2. One-shot NLU extraction  /extract   (Feature 7: deterministic pre-extract
#                                            + LLM, fence-tolerant JSON parsing)
#   3. Conversational extraction  /api/chat (multi-turn session in PostgreSQL chat_session)
#   4. Generate repository  /generate       (happy path)
#        ├─ Feature 4: IKD cross-check
#        ├─ template selection via Weaviate RAG
#        ├─ Feature 3: registry insert (PostgreSQL)
#        ├─ Feature 6: repo scaffolding (filesystem)
#        └─ Feature 5: notification email (MailDev)
#   5. Idempotency  /generate (re-run)      (Feature 3: duplicate detection)
#   6. Guardrail   /generate (bad IKD)      (Feature 4: validation failure)
#   7. Side-effect proof                    (DB row, scaffold file, email)
#
# Usage:
#   ./demo/run-demo.sh          # interactive — pause before each step
#   ./demo/run-demo.sh --auto   # run end-to-end without pausing
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

BASE="http://localhost:9999"
PG_CONTAINER="flogo-studio-postgres"
PG_DB="flogo_agent_studio"
MAILDEV_API="http://localhost:1080/email"
SCAFFOLD_DIR="generated-repos"

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[1;36m'; M='\033[0;35m'; D='\033[2m'; N='\033[0m'
else
  G=''; Y=''; R=''; B=''; M=''; D=''; N=''
fi

pause() {
  [[ "$AUTO" == 1 ]] && { echo; return; }
  echo -e "\n${D}  ↵ press Enter to run…${N}"; read -r _ </dev/tty
}
title() { echo -e "\n${B}━━━ $* ━━━${N}"; }
note()  { echo -e "${M}» $*${N}"; }
run()   { echo -e "${D}\$ $*${N}"; }

pretty() { python3 -m json.tool 2>/dev/null || cat; }

post() { # post <path> <json>
  curl -s -m 300 -X POST "$BASE$1" -H "Content-Type: application/json" -d "$2"
}

# ---- preflight -------------------------------------------------------------
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$BASE/health" 2>/dev/null)" != "200" ]]; then
  echo -e "${R}App is not healthy on $BASE.${N} Start it first:  ./demo/start-demo.sh"
  exit 1
fi

clear 2>/dev/null || true
echo -e "${B}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   BWCE AI Generator — Agentic AI on TIBCO Flogo               ║"
echo "║   Natural language  ➜  validated spec  ➜  BWCE repository     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${N}"

# ── 1. Health & template catalog ───────────────────────────────────────────
title "1. Platform up & template catalog (VectorDB ingestion)"
note "On startup the app ingests the template registry into Weaviate (RAG)."
pause
run "GET /health"; curl -s "$BASE/health" | pretty
echo
run "GET /api/templates"; curl -s "$BASE/api/templates" | pretty | head -40

# ── 2. One-shot NLU extraction ─────────────────────────────────────────────
title "2. One-shot NLU extraction  →  POST /extract   (Feature 7)"
note "Deterministic rule-engine pre-extract feeds the LLM; small-model JSON is"
note "sanitized (code-fences stripped) before parsing. Watch the structured result."
EXTRACT_PAYLOAD='{"message":"publish IKD-007 article from s4hana to kafka, scenario 1234, PROD, cdm required","current_spec":{}}'
run "POST /extract  $EXTRACT_PAYLOAD"
pause
post "/extract" "$EXTRACT_PAYLOAD" | pretty

# ── 3. Conversational extraction ───────────────────────────────────────────
title "3. Conversational extraction  →  POST /api/chat/*"
note "Sessions are persisted in PostgreSQL (chat_session); the assistant asks for missing fields."
pause
run "POST /api/chat/init"
INIT="$(post /api/chat/init '{}')"; echo "$INIT" | pretty
SID="$(echo "$INIT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
note "session_id = $SID"
echo
run "POST /api/chat/message  (describe the integration)"
post /api/chat/message "{\"session_id\":\"$SID\",\"message\":\"publish article from s4hana to kafka, scenario 1234, PROD\"}" | pretty

# ── 4. Generate repository (happy path) ────────────────────────────────────
title "4. Generate repository  →  POST /generate   (the full pipeline)"
note "IKD cross-check (F4) → template RAG → registry insert (F3) → scaffold (F6) → email (F5)"
GEN_PAYLOAD='{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"article","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic_CDM","cdm":true,"email":"developer@adidas.com","env":"DEV","k8s_domain":"cite","scenario_id":"1234","bw_profile":"default"}}'
run "POST /generate  (s4hana ➜ kafka, article, pub)"
pause
post "/generate" "$GEN_PAYLOAD" | pretty

# ── 5. Idempotency / duplicate detection ───────────────────────────────────
title "5. Idempotency  →  POST /generate (same spec again)   (Feature 3)"
note "Re-running the same spec must NOT scaffold again — it returns the existing record."
pause
post "/generate" "$GEN_PAYLOAD" | pretty

# ── 6. Guardrail / IKD validation failure ──────────────────────────────────
title "6. Guardrail  →  POST /generate (unknown IKD id)   (Feature 4)"
note "An interface_id outside the IKD registry is rejected before any side effects."
BAD_PAYLOAD='{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"order","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic_CDM","cdm":true,"email":"d@adidas.com","env":"DEV","k8s_domain":"cite","interface_id":"IKD-DOESNOTEXIST","bw_profile":"default"}}'
run "POST /generate  (interface_id = IKD-DOESNOTEXIST)"
pause
post "/generate" "$BAD_PAYLOAD" | pretty

# ── 7. Side-effect proof ───────────────────────────────────────────────────
title "7. Proof of side effects"
note "PostgreSQL generation registry (Feature 3):"
run "psql -d $PG_DB -c 'select repo_name,status,template_type,scenario_id from generation_log;'"
docker exec "$PG_CONTAINER" psql -U flogo -d "$PG_DB" \
  -c "select repo_name,status,template_type,scenario_id,created_at from generation_log order by created_at desc limit 5;" 2>/dev/null \
  || echo "  (could not query postgres)"
echo
note "Scaffolded repository on disk (Feature 6):"
run "find $SCAFFOLD_DIR -maxdepth 2 -type f"
find "$SCAFFOLD_DIR" -maxdepth 2 -type f 2>/dev/null | head || echo "  (no scaffold dir)"
echo
note "Notification email captured by MailDev (Feature 5):"
curl -s -m 5 "$MAILDEV_API" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(f"  {len(d)} email(s) in inbox")
for e in d[-3:]:
    to=[t.get("address") for t in e.get("to",[])]
    print("  •", e.get("subject"), "->", to)' 2>/dev/null \
  || echo "  (maildev inbox empty or unreachable)"
note "Open the inbox UI:  http://localhost:1080"

echo -e "\n${G}━━━ Demo complete ━━━${N}"
echo -e "${D}Tip: reset the registry between runs with:"
echo -e "  docker exec $PG_CONTAINER psql -U flogo -d $PG_DB -c 'TRUNCATE generation_log;'${N}"
