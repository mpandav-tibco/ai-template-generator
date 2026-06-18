#!/usr/bin/env bash
# ============================================================================
# BWCE AI Generator — Demo Startup Script
# ----------------------------------------------------------------------------
# Brings up every prerequisite the demo needs and (optionally) builds + starts
# the Flogo application, then waits until the API is healthy.
#
#   Prerequisites started / verified:
#     1. Docker engine running
#     2. PostgreSQL          (container: flogo-studio-postgres, :5432)
#     3. Weaviate VectorDB   (container: weaviate,             :18080)
#     4. MailDev SMTP + UI   (compose: docker-compose.maildev.yml, :1025 / :1080)
#     5. Ollama LLM runtime  (host,    :11434  + required models)
#     6. Flogo app           (./bwce-ai-generator,            :9999 / MCP :8081)
#
# Usage:
#   ./demo/start-demo.sh            # verify deps + start the app (uses existing binary)
#   ./demo/start-demo.sh --build    # rebuild the binary first, then start
#   ./demo/start-demo.sh --no-app   # only start prerequisites, do not launch the app
#   ./demo/start-demo.sh --stop     # stop the app + maildev (leaves pg/weaviate/ollama up)
# ============================================================================
set -uo pipefail

# ---- resolve paths ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

# ---- config ----------------------------------------------------------------
APP_BIN="bwce-ai-generator"
APP_FLOGO="bwce-ai-generator.flogo"
APP_LOG="/tmp/bwce-ai-generator.log"
FCLI_CONTEXT="flogo-studio-2264"
API_URL="http://localhost:9999"
MCP_URL="http://localhost:8081"

PG_CONTAINER="flogo-studio-postgres"
WEAVIATE_CONTAINER="weaviate"
MAILDEV_COMPOSE="docker-compose.maildev.yml"

OLLAMA_HOST="127.0.0.1:11434"
REQUIRED_MODELS=("llama3.1:8b" "nomic-embed-text")

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[0;36m'; D='\033[2m'; N='\033[0m'
else
  G=''; Y=''; R=''; B=''; D=''; N=''
fi
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
err()  { echo -e "  ${R}✗${N} $*"; }
step() { echo -e "\n${B}▶ $*${N}"; }

# ---- arg parsing -----------------------------------------------------------
DO_BUILD=0; START_APP=1; DO_STOP=0
for arg in "$@"; do
  case "$arg" in
    --build)  DO_BUILD=1 ;;
    --no-app) START_APP=0 ;;
    --stop)   DO_STOP=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) err "unknown option: $arg"; exit 2 ;;
  esac
done

# ---- stop mode -------------------------------------------------------------
if [[ "$DO_STOP" == 1 ]]; then
  step "Stopping demo app + MailDev"
  pkill -f "$APP_BIN" 2>/dev/null && ok "app stopped" || warn "app was not running"
  docker compose -f "$MAILDEV_COMPOSE" down >/dev/null 2>&1 && ok "maildev stopped" || warn "maildev not running"
  echo -e "\n${D}PostgreSQL / Weaviate / Ollama left running (shared services).${N}"
  exit 0
fi

# ---- 1. Docker -------------------------------------------------------------
step "1/6  Docker engine"
if ! docker info >/dev/null 2>&1; then
  err "Docker is not running. Start Docker Desktop and re-run."
  exit 1
fi
ok "docker is running"

# ---- helper: ensure a named container is running ---------------------------
ensure_container() {
  local name="$1" label="$2"
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then
    ok "$label already running ($name)"
  elif docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker start "$name" >/dev/null && ok "$label started ($name)" \
      || { err "failed to start $name"; return 1; }
  else
    err "$label container '$name' not found. Create it first (shared infra)."
    return 1
  fi
}

# ---- 2. PostgreSQL ---------------------------------------------------------
step "2/6  PostgreSQL (generation registry)"
ensure_container "$PG_CONTAINER" "PostgreSQL :5432"
if docker exec "$PG_CONTAINER" pg_isready -U flogo -d flogo_agent_studio >/dev/null 2>&1; then
  ok "database flogo_agent_studio reachable"
else
  warn "pg_isready did not confirm yet (may still be starting)"
fi

# ---- 3. Weaviate -----------------------------------------------------------
step "3/6  Weaviate VectorDB"
ensure_container "$WEAVIATE_CONTAINER" "Weaviate :18080"
if curl -fsS -m 5 "http://localhost:18080/v1/.well-known/ready" >/dev/null 2>&1; then
  ok "weaviate is ready"
else
  warn "weaviate not ready yet on :18080"
fi

# ---- 4. MailDev ------------------------------------------------------------
step "4/6  MailDev SMTP + inbox"
docker compose -f "$MAILDEV_COMPOSE" up -d >/dev/null 2>&1 \
  && ok "maildev up (SMTP :1025, inbox http://localhost:1080)" \
  || err "failed to start maildev"

# ---- 5. Ollama -------------------------------------------------------------
step "5/6  Ollama LLM runtime"
if curl -fsS -m 3 "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
  ok "ollama already serving on ${OLLAMA_HOST}"
else
  if command -v ollama >/dev/null 2>&1; then
    OLLAMA_HOST="$OLLAMA_HOST" nohup ollama serve >/tmp/ollama.log 2>&1 &
    disown || true
    for _ in {1..15}; do
      curl -fsS -m 2 "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -fsS -m 2 "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1 \
      && ok "ollama started on ${OLLAMA_HOST}" || err "ollama failed to start (see /tmp/ollama.log)"
  else
    err "ollama binary not found on PATH"
  fi
fi
# verify required models
INSTALLED="$(curl -fsS -m 3 "http://${OLLAMA_HOST}/api/tags" 2>/dev/null \
  | python3 -c 'import sys,json;print(" ".join(m["name"] for m in json.load(sys.stdin).get("models",[])))' 2>/dev/null || true)"
for m in "${REQUIRED_MODELS[@]}"; do
  if echo " $INSTALLED " | grep -q " ${m} \|${m%%:*}:"; then
    ok "model present: $m"
  else
    warn "model '$m' missing — pulling..."
    ollama pull "$m" && ok "pulled $m" || err "failed to pull $m"
  fi
done

# ---- optional build --------------------------------------------------------
if [[ "$DO_BUILD" == 1 ]]; then
  step "Build  Compiling Flogo binary (context $FCLI_CONTEXT)"
  if ! command -v fcli >/dev/null 2>&1; then
    err "fcli not found on PATH"; exit 1
  fi
  if fcli build-exe -f "$APP_FLOGO" -c "$FCLI_CONTEXT" -n "$APP_BIN" -o . >/tmp/bwce-build.log 2>&1; then
    ok "binary built: ./$APP_BIN"
  else
    err "build failed — see /tmp/bwce-build.log"; tail -5 /tmp/bwce-build.log; exit 1
  fi
fi

# ---- 6. Start the app ------------------------------------------------------
if [[ "$START_APP" == 0 ]]; then
  echo -e "\n${G}Prerequisites ready.${N} Skipping app launch (--no-app)."
  exit 0
fi

step "6/6  Flogo application"
if [[ ! -x "./$APP_BIN" ]]; then
  err "binary ./$APP_BIN not found. Run with --build first."
  exit 1
fi
pkill -f "$APP_BIN" 2>/dev/null && sleep 1 || true
nohup "./$APP_BIN" >"$APP_LOG" 2>&1 </dev/null &
disown || true

# wait for health
for _ in {1..20}; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$API_URL/health" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && break
  sleep 1
done

echo
if [[ "${code:-000}" == "200" ]]; then
  echo -e "${G}════════════════════════════════════════════════════════════${N}"
  echo -e "${G} BWCE AI Generator is UP${N}"
  echo -e "${G}════════════════════════════════════════════════════════════${N}"
  echo -e "  REST API     ${API_URL}"
  echo -e "  MCP server   ${MCP_URL}"
  echo -e "  MailDev UI   http://localhost:1080"
  echo -e "  App log      ${APP_LOG}"
  echo
  echo -e "  Next:  ${B}./demo/run-demo.sh${N}"
else
  err "app did not become healthy — check $APP_LOG"
  tail -15 "$APP_LOG" 2>/dev/null
  exit 1
fi
