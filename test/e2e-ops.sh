#!/usr/bin/env bash
# End-to-end suite for the operations features of bwce-ai-generator-github: auth, accounts, audit,
# Kubernetes, code review, schema upload and the IKD registry.
#   AUTH_API_KEY=... bash test/e2e-ops.sh
# Optional: E2E_REPO=<generated repository> (schema upload), K8S_DEPLOYMENT=<name> (scale/restart round trip).
set -u
B=${BASE_URL:-http://localhost:9999}
P=0; F=0; S=0
ok()   { P=$((P+1)); echo "PASS  $1"; }
bad()  { F=$((F+1)); echo "FAIL  $1  :: $2"; }
skip() { S=$((S+1)); echo "SKIP  $1"; }
j()    { python3 -c "import json,sys; d=json.load(open(sys.argv[2])); print(eval(sys.argv[1]))" "$1" /tmp/e2e-ops.json; }
[ -n "${AUTH_API_KEY:-}" ] || { echo "set AUTH_API_KEY"; exit 2; }
KEYRC=$(mktemp); trap 'rm -f "$KEYRC"' EXIT
printf 'header = "X-API-Key: %s"\n' "$AUTH_API_KEY" > "$KEYRC"
# req METHOD PATH [BODY] [extra curl args...] -> prints the HTTP status, body in /tmp/e2e-ops.json
req()  { local m="$1" p="$2" b="${3:-}"; shift 3 2>/dev/null || shift $#
         local a=(-s -o /tmp/e2e-ops.json -w '%{http_code}' -X "$m" "$B$p" -H 'Content-Type: application/json')
         [ -n "$b" ] && a+=(-d "$b")
         curl "${a[@]}" "$@"; }
key()  { req "$1" "$2" "${3:-}" -K "$KEYRC"; }
login(){ curl -s -D - -o /tmp/e2e-ops.json -X POST "$B/api/login" -H 'Content-Type: application/json' \
           -d "{\"username\":\"$1\",\"password\":\"$2\"}" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: session=\([^;]*\).*/\1/p'; }
T=$$; R="e2e-reader-$T"; L="e2e-lock-$T"; PW="E2e-pass-$T!"

# 1. public vs protected
[ "$(req GET /)" = 200 ] && ok "UI is public" || bad "UI is public" "not 200"
[ "$(req GET /api/templates)" = 401 ] && [ "$(j "d['code']")" = UNAUTHENTICATED ] && ok "protected without credentials -> 401" || bad "401" "$(cat /tmp/e2e-ops.json)"
[ "$(req GET /docs)" = 401 ] && ok "/docs is protected" || bad "/docs" "not 401"
[ "$(key GET /api/templates)" = 200 ] && ok "X-API-Key grants access" || bad "api key" "not 200"
[ "$(req GET /api/templates '' -H 'X-API-Key: wrong')" = 401 ] && ok "wrong API key -> 401" || bad "wrong key" "not 401"

# 2. accounts, login, roles, lockout
body="{\"username\":\"$R\",\"password\":\"$PW\",\"displayName\":\"E2E Reader\",\"role\":\"reader\"}"
[ "$(key POST /api/users "$body")" = 200 ] && ok "create reader account" || bad "create reader" "$(cat /tmp/e2e-ops.json)"
[ "$(key POST /api/users '{"username":"x","password":"short"}')" = 400 ] && ok "weak password rejected" || bad "weak password" "not 400"
tok=$(login "$R" "$PW")
[ -n "$tok" ] && [ "$(j "d['role']")" = reader ] && ok "login sets the session cookie" || bad "login" "$(cat /tmp/e2e-ops.json)"
[ "$(req GET /api/session '' -H "Cookie: session=$tok")" = 200 ] && [ "$(j "d['authenticated']")" = True ] && ok "session probe" || bad "session" "$(cat /tmp/e2e-ops.json)"
[ "$(req GET /api/templates '' -H "Authorization: Bearer $tok")" = 200 ] && ok "bearer token accepted" || bad "bearer" "not 200"
[ "$(req GET /api/users '' -H "Cookie: session=$tok")" = 403 ] && ok "reader on admin endpoint -> 403" || bad "403" "$(cat /tmp/e2e-ops.json)"
[ "$(req GET /api/templates '' -H "Cookie: session=${tok}x")" = 401 ] && ok "tampered token -> 401" || bad "tampered" "not 401"
key POST /api/users "{\"username\":\"$L\",\"password\":\"$PW\",\"role\":\"reader\"}" > /dev/null
for _ in 1 2 3 4 5; do login "$L" wrong-password > /dev/null; done
login "$L" "$PW" > /dev/null
[ "$(j "d.get('detail','')")" != "" ] && j "d['detail']" | grep -q '^Too many failed attempts' && ok "lockout after 5 failures (429)" || bad "lockout" "$(cat /tmp/e2e-ops.json)"
[ "$(req POST /api/logout '' -H "Cookie: session=$tok")" = 200 ] && ok "logout" || bad "logout" "not 200"
[ "$(key GET '/api/auditlog?limit=50')" = 200 ] && j "[e['action'] for e in d['entries']]" | grep -q login_locked_out && ok "audit log records login_locked_out" || bad "audit" "missing"
for u in "$R" "$L"; do key DELETE "/api/users?username=$u" > /dev/null; done
[ "$(key DELETE "/api/users?username=$R")" = 404 ] && ok "deleted accounts are gone (404)" || bad "delete" "not 404"
[ "$(key GET /api/auth/diagnostics)" = 200 ] && [ "$(j "d['auth_enabled']")" = True ] && ok "auth diagnostics" || bad "diagnostics" "$(cat /tmp/e2e-ops.json)"

# 3. Kubernetes
if [ "$(key GET /k8s/health)" = 200 ] && [ "$(j "d['success']")" = True ]; then
  ok "k8s health ($(j "d['server_version']"))"
  for p in status deployments pods services 'events?limit=5' context; do
    [ "$(key GET "/k8s/$p")" = 200 ] && ok "k8s GET /k8s/$p" || bad "k8s $p" "$(head -c 200 /tmp/e2e-ops.json)"
  done
  [ "$(key GET /k8s/deployments/does-not-exist)" = 404 ] && ok "k8s unknown deployment -> 404" || bad "k8s 404" "not 404"
  [ "$(key GET '/k8s/pods/Bad_Name/logs')" = 400 ] && ok "k8s invalid name -> 400" || bad "k8s 400" "not 400"
  if [ -n "${K8S_DEPLOYMENT:-}" ]; then
    n=$(key GET "/k8s/deployments/$K8S_DEPLOYMENT" > /dev/null; j "d['deployment']['replicas_desired']")
    [ "$(key POST "/k8s/deployments/$K8S_DEPLOYMENT/scale" "{\"replicas\":$((n+1))}")" = 200 ] && ok "k8s scale up" || bad "scale" "$(cat /tmp/e2e-ops.json)"
    [ "$(key POST "/k8s/deployments/$K8S_DEPLOYMENT/scale" "{\"replicas\":$n}")" = 200 ] && ok "k8s scale back to $n" || bad "scale back" "$(cat /tmp/e2e-ops.json)"
    [ "$(key POST "/k8s/deployments/$K8S_DEPLOYMENT/restart" '{}')" = 200 ] && ok "k8s restart" || bad "restart" "$(cat /tmp/e2e-ops.json)"
  else skip "k8s scale/restart (set K8S_DEPLOYMENT)"; fi
else skip "Kubernetes (cluster not reachable: $(head -c 120 /tmp/e2e-ops.json))"; fi

# 4. code review
c=$(key POST /api/codereview/token '{}')
if [ "$c" = 200 ]; then
  ok "code review token"
  [ "$(key POST /api/codereview/run '{"repoName":"r"}')" = 400 ] && ok "code review validation -> 400" || bad "cr validation" "not 400"
  [ "$(key GET /api/codereview/history)" = 200 ] && ok "code review history" || bad "cr history" "not 200"
elif [ "$c" = 503 ]; then skip "code review (not configured)"; else bad "code review token" "$c $(cat /tmp/e2e-ops.json)"; fi

# 5. schemas + IKD
[ "$(key POST /api/schemas/upload/source '{"repository_name":"../x","filename":"a.xsd","content":"<a/>"}')" = 400 ] && ok "schema upload rejects path traversal" || bad "schema 400" "not 400"
if [ -n "${E2E_REPO:-}" ]; then
  body="{\"repository_name\":\"$E2E_REPO\",\"filename\":\"E2eType.xsd\",\"content\":\"<xsd:schema xmlns:xsd=\\\"http://www.w3.org/2001/XMLSchema\\\"><xsd:complexType name=\\\"E2eType\\\"/></xsd:schema>\"}"
  [ "$(key POST /api/schemas/upload/source "$body")" = 200 ] && [ "$(j "d['uploaded_files'][1]['complex_type_used']")" = E2eType ] \
    && ok "schema upload committed ($(j "d['commit_sha'][:7]"))" || bad "schema upload" "$(cat /tmp/e2e-ops.json)"
  curl -s -K "$KEYRC" "$B/api/ikd?kind=InterfaceIDs" | grep -q ":$E2E_REPO\$" && ok "IKD registry lists $E2E_REPO" || bad "IKD" "missing"
else skip "schema upload + IKD (set E2E_REPO to a generated repository)"; fi

echo; echo "$P passed, $F failed, $S skipped"; [ "$F" = 0 ]
