#!/usr/bin/env bash
# =============================================================================
# BWCE AI Generator - Automated Flow Test Suite
# =============================================================================
# Black-box integration tests covering every flow/endpoint with assertions.
# CI-ready: prints a PASS/FAIL summary and exits non-zero on any failure.
#
# Usage:
#   ./test/api-test.sh                      # functional suite
#   ./test/api-test.sh --with-resilience    # also run the DB-down 500 test
#                                           # (briefly stops the postgres container)
#
# Requirements: curl, jq. The app must be running on $BASE_URL.
# DB-backed assertions (audit row, session row, duplicate) use the postgres
# container and are skipped with a warning if it is not reachable.
# =============================================================================
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:9999}"
PG_CONTAINER="${PG_CONTAINER:-flogo-studio-postgres}"
PG_USER="${PG_USER:-flogo}"
PG_DB="${PG_DB:-flogo_agent_studio}"
RUN_RESILIENCE=false
[[ "${1:-}" == "--with-resilience" ]] && RUN_RESILIENCE=true

RUN_ID="$(date +%s)"          # unique suffix so repeated runs don't collide
PASS=0; FAIL=0; SKIP=0
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; CYA=$'\033[0;36m'; NC=$'\033[0m'

section(){ echo ""; echo "${CYA}=== $* ===${NC}"; }
pass(){ PASS=$((PASS+1)); echo "  ${GREEN}PASS${NC} $*"; }
fail(){ FAIL=$((FAIL+1)); echo "  ${RED}FAIL${NC} $*"; }
skip(){ SKIP=$((SKIP+1)); echo "  ${YEL}SKIP${NC} $*"; }

# assert_http <label> <expected_code> <method> <path> [json_body]  -> body in /tmp/att_body.json
assert_http(){
  local label="$1" exp="$2" method="$3" path="$4" body="${5:-}" code
  if [[ -n "$body" ]]; then
    code=$(curl -s -o /tmp/att_body.json -w '%{http_code}' -X "$method" "$BASE_URL$path" \
           -H 'Content-Type: application/json' -d "$body")
  else
    code=$(curl -s -o /tmp/att_body.json -w '%{http_code}' -X "$method" "$BASE_URL$path")
  fi
  if [[ "$code" == "$exp" ]]; then pass "$label (HTTP $code)"; else fail "$label (expected $exp, got $code)"; fi
}

# assert_jq <label> <jq_filter> <expected>   (operates on /tmp/att_body.json)
assert_jq(){
  local label="$1" filter="$2" exp="$3" got
  got=$(jq -r "$filter" /tmp/att_body.json 2>/dev/null)
  if [[ "$got" == "$exp" ]]; then pass "$label"; else fail "$label ($filter: expected '$exp', got '$got')"; fi
}

# assert_contains <label> <substring>        (operates on /tmp/att_body.json)
assert_contains(){
  local label="$1" sub="$2"
  if grep -q "$sub" /tmp/att_body.json 2>/dev/null; then pass "$label"; else fail "$label (missing '$sub')"; fi
}

psql_q(){ docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null; }
have_db(){ docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" >/dev/null 2>&1; }

echo "BWCE AI Generator - Flow Test Suite   (run id: $RUN_ID)"
echo "Target: $BASE_URL"

# --- preflight ---------------------------------------------------------------
if ! curl -s -o /dev/null "$BASE_URL/health"; then
  echo "${RED}App not reachable at $BASE_URL - is it running?${NC}"; exit 2
fi
DB_OK=false; have_db && DB_OK=true

# =============================================================================
section "1. Static / health endpoints"
assert_http "GET /health"        200 GET /health
assert_http "GET / (chat UI)"    200 GET /
assert_contains "/ serves HTML"  "<html"
assert_http "GET /docs"          200 GET /docs
assert_http "GET /openapi.json"  200 GET /openapi.json
assert_jq  "openapi is 3.x"      '.openapi | startswith("3")' true
assert_http "GET /api/templates" 200 GET /api/templates

# =============================================================================
section "2. /generate - happy paths"
OBJ="auto${RUN_ID}"
GEN_FULL="{\"spec\":{\"source_system\":\"s4hana\",\"target_system\":\"kafka\",\"business_object\":\"${OBJ}\",\"interface_type\":\"pub\",\"template_type\":\"S4HANA_PUB_To_KAFKATopic_CDM\",\"cdm\":true,\"email\":\"dev@adidas.com\",\"interface_id\":\"IKD-001\",\"bitbucket_project\":\"INTEG\"}}"
assert_http "full generate"      200 POST /generate "$GEN_FULL"
assert_jq  "success=true"        '.success' true
assert_jq  "repo_name correct"   '.repo_name' "s4hana-${OBJ}-kafka-pub"
assert_jq  "template resolved"   '.template_name' "S4HANA_PUB_To_KAFKATopic"

OBJC="autocfg${RUN_ID}"
GEN_CFG="{\"config_only\":true,\"spec\":{\"source_system\":\"s4hana\",\"target_system\":\"kafka\",\"business_object\":\"${OBJC}\",\"interface_type\":\"pub\",\"template_type\":\"S4HANA_PUB_To_KAFKATopic_CDM\",\"email\":\"dev@adidas.com\",\"interface_id\":\"IKD-001\",\"bitbucket_project\":\"INTEG\"}}"
assert_http "config-only generate" 200 POST /generate "$GEN_CFG"
assert_jq  "success=true"          '.success' true

# =============================================================================
section "3. /generate - validation (HTTP 400)"
assert_http "missing source_system" 400 POST /generate \
  "{\"spec\":{\"target_system\":\"kafka\",\"business_object\":\"v${RUN_ID}a\",\"interface_type\":\"pub\",\"template_type\":\"X\",\"email\":\"dev@adidas.com\",\"bitbucket_project\":\"INTEG\"}}"
assert_jq  "error=VALIDATION_FAILED" '.error' VALIDATION_FAILED
assert_http "invalid interface_type" 400 POST /generate \
  "{\"spec\":{\"source_system\":\"s4hana\",\"target_system\":\"kafka\",\"business_object\":\"v${RUN_ID}b\",\"interface_type\":\"badtype\",\"template_type\":\"X\",\"email\":\"dev@adidas.com\",\"bitbucket_project\":\"INTEG\"}}"
assert_http "source==target"         400 POST /generate \
  "{\"spec\":{\"source_system\":\"kafka\",\"target_system\":\"kafka\",\"business_object\":\"v${RUN_ID}c\",\"interface_type\":\"pub\",\"template_type\":\"X\",\"email\":\"dev@adidas.com\",\"bitbucket_project\":\"INTEG\"}}"
assert_http "bad email domain"       400 POST /generate \
  "{\"spec\":{\"source_system\":\"s4hana\",\"target_system\":\"kafka\",\"business_object\":\"v${RUN_ID}d\",\"interface_type\":\"pub\",\"template_type\":\"X\",\"email\":\"dev@gmail.com\",\"bitbucket_project\":\"INTEG\"}}"

# =============================================================================
section "4. /generate - duplicate detection"
assert_http "re-generate same repo" 200 POST /generate "$GEN_FULL"
if $DB_OK; then
  CNT=$(psql_q "SELECT count(*) FROM generation_log WHERE repo_name='s4hana-${OBJ}-kafka-pub';")
  [[ "$CNT" == "1" ]] && pass "duplicate not re-inserted (count=1)" || fail "duplicate guard (count=$CNT, expected 1)"
else skip "duplicate DB count (postgres not reachable)"; fi

# =============================================================================
section "5. DB audit (generation_log)"
if $DB_OK; then
  ST=$(psql_q "SELECT status FROM generation_log WHERE repo_name='s4hana-${OBJ}-kafka-pub' LIMIT 1;")
  [[ "$ST" == "GENERATED" ]] && pass "audit row recorded (status=GENERATED)" || fail "audit row (status=$ST)"
else skip "audit row (postgres not reachable)"; fi

# =============================================================================
section "6. /extract (one-shot NLU)"
assert_http "extract" 200 POST /extract \
  '{"message":"publish article from s4hana to kafka","current_spec":{}}'
assert_jq  "source extracted" '.spec.source_system' S4HANA
assert_jq  "target extracted" '.spec.target_system' KAFKA

# =============================================================================
section "7. Chat - session lifecycle + persistence"
SID=$(curl -s -X POST "$BASE_URL/api/chat/init" -H 'Content-Type: application/json' -d '{}' | jq -r '.session_id')
[[ -n "$SID" && "$SID" != "null" ]] && pass "init returns session_id" || fail "init session_id ($SID)"
if $DB_OK; then
  RC=$(psql_q "SELECT count(*) FROM chat_session WHERE session_id='$SID';")
  [[ "$RC" == "1" ]] && pass "session persisted in chat_session" || fail "session row (count=$RC)"
else skip "session row (postgres not reachable)"; fi

assert_http "turn 1 (s4hana->kafka)" 200 POST /api/chat/message \
  "{\"session_id\":\"$SID\",\"message\":\"publish from s4hana to kafka\"}"
assert_jq  "source extracted" '.spec.source_system' S4HANA
assert_jq  "target extracted" '.spec.target_system' KAFKA

# turn 2 retains turn-1 spec read back from the DB (cross-call persistence)
assert_http "turn 2 (add object)" 200 POST /api/chat/message \
  "{\"session_id\":\"$SID\",\"message\":\"for invoice business object\"}"
assert_jq  "source retained from DB" '.spec.source_system' S4HANA
assert_jq  "target retained from DB" '.spec.target_system' KAFKA

# unknown session is graceful (fresh spec, no 500)
assert_http "unknown session graceful" 200 POST /api/chat/message \
  "{\"session_id\":\"no-such-session-${RUN_ID}\",\"message\":\"publish from sap to mq\"}"

# reset deletes the row
assert_http "reset" 200 POST /api/chat/reset "{\"session_id\":\"$SID\"}"
if $DB_OK; then
  RC=$(psql_q "SELECT count(*) FROM chat_session WHERE session_id='$SID';")
  [[ "$RC" == "0" ]] && pass "session row deleted on reset" || fail "reset delete (count=$RC)"
else skip "reset delete (postgres not reachable)"; fi

# =============================================================================
section "8. Resilience - flow error handler (HTTP 500)"
if $RUN_RESILIENCE && $DB_OK; then
  echo "  (stopping $PG_CONTAINER to force a DB failure...)"
  docker stop "$PG_CONTAINER" >/dev/null 2>&1; sleep 1
  assert_http "DB down -> 500" 500 POST /generate \
    "{\"spec\":{\"source_system\":\"s4hana\",\"target_system\":\"kafka\",\"business_object\":\"res${RUN_ID}\",\"interface_type\":\"pub\",\"template_type\":\"S4HANA_PUB_To_KAFKATopic_CDM\",\"email\":\"dev@adidas.com\",\"interface_id\":\"IKD-001\",\"bitbucket_project\":\"INTEG\"}}"
  assert_jq  "structured error body" '.error' INTERNAL_ERROR
  assert_jq  "names failing activity" '.activity' CheckDuplicate
  echo "  (restarting $PG_CONTAINER...)"
  docker start "$PG_CONTAINER" >/dev/null 2>&1; sleep 4
  echo "  ${YEL}NOTE:${NC} restart the app to refresh its DB connection pool after this test."
else
  skip "resilience test (run with --with-resilience; needs postgres container)"
fi

# =============================================================================
echo ""
echo "${CYA}==================== SUMMARY ====================${NC}"
echo "  ${GREEN}PASS: $PASS${NC}   ${RED}FAIL: $FAIL${NC}   ${YEL}SKIP: $SKIP${NC}"
echo "${CYA}=================================================${NC}"
[[ "$FAIL" -eq 0 ]] && { echo "${GREEN}ALL TESTS PASSED${NC}"; exit 0; } || { echo "${RED}TESTS FAILED${NC}"; exit 1; }
