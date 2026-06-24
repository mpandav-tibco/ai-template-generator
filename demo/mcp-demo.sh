#!/usr/bin/env bash
# ============================================================================
# BWCE AI Generator — MCP tool caller (demo helper)
# ----------------------------------------------------------------------------
# Drives the MCP server (Streamable HTTP) end-to-end: initialize -> initialized
# -> tools/call, and prints the tool's text result. Used by the demo to show
# the same engine that powers the REST API exposed to AI agents (Claude/Copilot).
#
# Usage:
#   ./demo/mcp-demo.sh list_templates
#   ./demo/mcp-demo.sh extract_spec  '{"message":"publish article from s4hana to kafka"}'
#   ./demo/mcp-demo.sh generate_code '{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"article","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"dev@adidas.com"}}'
# ============================================================================
set -uo pipefail

MCP_URL="${MCP_URL:-http://localhost:8081/mcp}"
TOOL="${1:-list_templates}"
ARGS="${2:-{}}"
HDR=(-H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")

# 1. initialize — the session id comes back in the Mcp-Session-Id response header
SID="$(curl -s -D - -o /dev/null -m 30 "${HDR[@]}" -X POST "$MCP_URL" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bwce-demo","version":"1.0"}}}' \
  | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')"

if [[ -z "$SID" ]]; then
  echo "Could not open an MCP session on $MCP_URL — is the app running? (./demo/start-demo.sh)" >&2
  exit 1
fi

# 2. initialized notification (no id — it's a notification)
curl -s -o /dev/null -m 30 "${HDR[@]}" -H "Mcp-Session-Id: $SID" -X POST "$MCP_URL" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 3. tools/call
curl -s -m 300 "${HDR[@]}" -H "Mcp-Session-Id: $SID" -X POST "$MCP_URL" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARGS}}" \
  | python3 -c '
import sys, json
raw = sys.stdin.read().strip()
obj = None
for line in raw.splitlines():            # tolerate SSE "data: {...}" framing
    line = line[5:].strip() if line.startswith("data:") else line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    break
if not obj:
    print("(no parseable MCP response)"); sys.exit(1)
if "error" in obj:
    print("MCP ERROR:", json.dumps(obj["error"])); sys.exit(1)
text = obj["result"]["content"][0]["text"]
try:                                     # pretty-print JSON payloads when possible
    print(json.dumps(json.loads(text), indent=2))
except Exception:
    print(text)
'
