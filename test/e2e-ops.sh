#!/usr/bin/env bash
# End-to-end suite for the operations features of bwce-ai-generator-github: Kubernetes, code review, schema upload
# and the IKD registry. Authentication is done by the API gateway (Kong) in front of the app, not by the app.
#   bash test/e2e-ops.sh
# Optional: E2E_REPO=<generated repository> (schema upload), K8S_DEPLOYMENT=<name> (scale/restart round trip).
set -u
B=${BASE_URL:-http://localhost:9999}
P=0; F=0; S=0
ok()   { P=$((P+1)); echo "PASS  $1"; }
bad()  { F=$((F+1)); echo "FAIL  $1  :: $2"; }
skip() { S=$((S+1)); echo "SKIP  $1"; }
j()    { python3 -c "import json,sys; d=json.load(open(sys.argv[2])); print(eval(sys.argv[1]))" "$1" /tmp/e2e-ops.json; }
# req METHOD PATH [BODY] -> prints the HTTP status, body in /tmp/e2e-ops.json
req()  { local a=(-s -o /tmp/e2e-ops.json -w '%{http_code}' -X "$1" "$B$2" -H 'Content-Type: application/json')
         [ -n "${3:-}" ] && a+=(-d "$3")
         curl "${a[@]}"; }

# 1. static pages; no sign-in or account endpoints in the app
[ "$(req GET /)" = 200 ] && ok "UI" || bad "UI" "not 200"
[ "$(req GET /docs)" = 200 ] && ok "API docs" || bad "/docs" "not 200"
[ "$(req GET /openapi.json)" = 200 ] && [ "$(j "len(d['paths'])")" -gt 0 ] && ok "API definition" || bad "/openapi.json" "not 200"
[ "$(req GET /api/templates)" = 200 ] && ok "endpoints need no credentials" || bad "no credentials" "$(head -c 200 /tmp/e2e-ops.json)"
for p in "POST /api/login" "GET /api/session" "GET /api/users" "GET /api/auditlog"; do
  [ "$(req $p)" = 404 ] && ok "$p removed (404)" || bad "$p" "not 404"
done

# 2. Kubernetes
if [ "$(req GET /k8s/health)" = 200 ] && [ "$(j "d['success']")" = True ]; then
  ok "k8s health ($(j "d['server_version']"))"
  for p in status deployments pods services 'events?limit=5' context; do
    [ "$(req GET "/k8s/$p")" = 200 ] && ok "k8s GET /k8s/$p" || bad "k8s $p" "$(head -c 200 /tmp/e2e-ops.json)"
  done
  [ "$(req GET /k8s/deployments/does-not-exist)" = 404 ] && ok "k8s unknown deployment -> 404" || bad "k8s 404" "not 404"
  [ "$(req GET '/k8s/pods/Bad_Name/logs')" = 400 ] && ok "k8s invalid name -> 400" || bad "k8s 400" "not 400"
  [ "$(req GET /k8s/scale)" = 404 ] && ok "k8s unknown route -> 404" || bad "k8s route 404" "not 404"
  if [ -n "${K8S_DEPLOYMENT:-}" ]; then
    n=$(req GET "/k8s/deployments/$K8S_DEPLOYMENT" > /dev/null; j "d['deployment']['replicas_desired']")
    [ "$(req POST "/k8s/deployments/$K8S_DEPLOYMENT/scale" "{\"replicas\":$((n+1))}")" = 200 ] && ok "k8s scale up" || bad "scale" "$(cat /tmp/e2e-ops.json)"
    [ "$(req POST "/k8s/deployments/$K8S_DEPLOYMENT/scale" "{\"replicas\":$n}")" = 200 ] && ok "k8s scale back to $n" || bad "scale back" "$(cat /tmp/e2e-ops.json)"
    [ "$(req POST "/k8s/deployments/$K8S_DEPLOYMENT/restart" '{}')" = 200 ] && ok "k8s restart" || bad "restart" "$(cat /tmp/e2e-ops.json)"
  else skip "k8s scale/restart (set K8S_DEPLOYMENT)"; fi
else skip "Kubernetes (cluster not reachable: $(head -c 120 /tmp/e2e-ops.json))"; fi

# 3. code review
c=$(req POST /api/codereview/token '{}')
if [ "$c" = 200 ]; then
  ok "code review token"
  [ "$(req POST /api/codereview/run '{"repoName":"r"}')" = 400 ] && ok "code review validation -> 400" || bad "cr validation" "not 400"
  [ "$(req GET /api/codereview/history)" = 200 ] && ok "code review history" || bad "cr history" "not 200"
elif [ "$c" = 503 ]; then skip "code review (not configured)"; else bad "code review token" "$c $(cat /tmp/e2e-ops.json)"; fi

# 4. schemas + IKD
[ "$(req POST /api/schemas/upload/source '{"repository_name":"../x","filename":"a.xsd","content":"<a/>"}')" = 400 ] && ok "schema upload rejects path traversal" || bad "schema 400" "not 400"
[ "$(req POST /api/schemas/upload/other '{"repository_name":"r1","filename":"a.xsd","content":"<a/>"}')" = 404 ] && ok "schema upload unknown kind -> 404" || bad "schema kind" "not 404"
if [ -n "${E2E_REPO:-}" ]; then
  body="{\"repository_name\":\"$E2E_REPO\",\"filename\":\"E2eType.xsd\",\"content\":\"<xsd:schema xmlns:xsd=\\\"http://www.w3.org/2001/XMLSchema\\\"><xsd:complexType name=\\\"E2eType\\\"/></xsd:schema>\"}"
  [ "$(req POST /api/schemas/upload/source "$body")" = 200 ] && [ "$(j "d['uploaded_files'][1]['complex_type_used']")" = E2eType ] \
    && ok "schema upload committed ($(j "d['commit_sha'][:7]"))" || bad "schema upload" "$(cat /tmp/e2e-ops.json)"
  curl -s "$B/api/ikd?kind=InterfaceIDs" | grep -q ":$E2E_REPO\$" && ok "IKD registry lists $E2E_REPO" || bad "IKD" "missing"
else skip "schema upload + IKD (set E2E_REPO to a generated repository)"; fi

echo; echo "$P passed, $F failed, $S skipped"; [ "$F" = 0 ]
