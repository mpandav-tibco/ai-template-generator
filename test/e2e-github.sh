#!/usr/bin/env bash
# End-to-end API suite for bwce-ai-generator-github (REST 9999, MCP 8081).
set -u
B=http://localhost:9999
P=0; F=0
ok()   { P=$((P+1)); echo "PASS  $1"; }
bad()  { F=$((F+1)); echo "FAIL  $1  :: $2"; }
jq_()  { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
post() { curl -s -X POST "$B$1" -H 'Content-Type: application/json' -d "$2"; }

# 1. health + catalog
[ "$(curl -s -o /dev/null -w '%{http_code}' $B/health)" = 200 ] && ok "health" || bad "health" "not 200"
n=$(curl -s $B/api/templates | jq_ "len(d['templates'])"); [ "$n" = 37 ] && ok "catalog has 37 templates" || bad "catalog" "$n"

# 2. suggestions use hybrid ranking
top=$(post /api/templates/suggest '{"source_system":"S4HANA","target_system":"KAFKA","business_object":"article","interface_type":"pub"}' | jq_ "d['suggestions'][0]['id']")
[ "$top" = SAP_IDOC_To_KAFKATopic ] && ok "suggest S4HANA->KAFKA pub = $top" || bad "suggest" "$top"

# 3. chat journey without a template; guarded fields must survive follow-ups
init=$(post /api/chat/init '{}'); sid=$(echo "$init" | jq_ "d['session_id']"); st=$(echo "$init" | jq_ "d['status']")
[ "$st" = active ] && ok "chat init status is plain 'active'" || bad "chat init status" "$st"
r1=$(post /api/chat/message "{\"session_id\":\"$sid\",\"message\":\"I need to publish article master data from S4HANA to Kafka\"}")
it1=$(echo "$r1" | jq_ "d['spec']['interface_type']")
r2=$(post /api/chat/message "{\"session_id\":\"$sid\",\"message\":\"the business object is article\"}")
it2=$(echo "$r2" | jq_ "d['spec']['interface_type']"); rd=$(echo "$r2" | jq_ "d['ready_to_generate']"); st2=$(echo "$r2" | jq_ "d['status']")
[ "$it1" = pub ] && [ "$it2" = pub ] && ok "interface_type kept across turns ($it1 -> $it2)" || bad "guarded merge" "$it1 -> $it2"
[ "$rd" = True ] && ok "chat ready without template" || bad "chat ready" "$rd"
[ "$st2" = active ] && ok "chat message status plain" || bad "chat message status" "$st2"

# 4. generate: hybrid template selection + product-area prefix + GitHub publish (unique uid per run;
#    no e-mail, as from the chat - defaults to "NA" like the reference generator)
uid=e$(date +%s | tail -c 6)
spec="{\"source_system\":\"S4HANA\",\"target_system\":\"KAFKA\",\"business_object\":\"Article\",\"interface_type\":\"pub\",\"product_area\":\"product_area-csddistribution\",\"env\":\"DEV\",\"unique_id\":\"$uid\"}"
g=$(post /generate "{\"spec\":$spec,\"config_only\":false}"); echo "$g" > /tmp/e2e-gen.json
repo=$(echo "$g" | jq_ "d.get('repo_name')"); tpl=$(echo "$g" | jq_ "d.get('template_name')"); pushed=$(echo "$g" | jq_ "d.get('pushed')")
[ "$repo" = "incsdsourcing-s4hana-article-kafka-$uid-pub" ] && ok "repo name (python rules) = $repo" || bad "repo name" "$repo"
[ "$tpl" = SAP_IDOC_To_KAFKATopic ] && ok "auto-selected template = $tpl" || bad "template" "$tpl"
[ "$pushed" = True ] && ok "published to GitHub ($(echo "$g" | jq_ "d['files_total']") files, $(echo "$g" | jq_ "d['scaffold_ms']") ms)" || bad "push" "$g"

# 5. re-generating is idempotent: returns the existing registration and GitHub folder, scaffolds nothing
d=$(post /generate "{\"spec\":$spec,\"config_only\":false}"); dup=$(echo "$d" | jq_ "str(d.get('duplicate'))+'|'+d.get('github_url','')")
case "$dup" in "True|"*"/tree/main/$repo") ok "duplicate is idempotent -> existing folder";; *) bad "duplicate" "$d";; esac

# 6. config-only refresh is allowed for an existing repo and only touches configs
c=$(post /generate "{\"spec\":$spec,\"config_only\":true}"); cm=$(echo "$c" | jq_ "d.get('message','')[:40]+'|'+str(d.get('pushed'))+'|'+str(d.get('files_total'))")
case "$cm" in Configuration*"|True|"*) ok "config-only refresh ($cm)";; *) bad "config-only" "$c";; esac

# 7. names over 50 characters are rejected like the reference generator
long='{"source_system":"S4HANA","target_system":"KAFKA","business_object":"averyveryverylongbusinessobjectnamexx","interface_type":"pub","product_area":"product_area-salescom","email":"dev@tibco.com"}'
code=$(curl -s -o /tmp/e2e-long.json -w '%{http_code}' -X POST $B/generate -H 'Content-Type: application/json' -d "{\"spec\":$long}")
grep -q repo_name_max_length /tmp/e2e-long.json && [ "$code" = 400 ] && ok "over-length name -> 400 repo_name_max_length" || bad "max length" "$code $(head -c 200 /tmp/e2e-long.json)"

# 7b. e-mail domains outside the allow-list are rejected
bad_mail='{"source_system":"S4HANA","target_system":"KAFKA","business_object":"article","interface_type":"pub","email":"dev@example.com"}'
code=$(curl -s -o /tmp/e2e-mail.json -w '%{http_code}' -X POST $B/generate -H 'Content-Type: application/json' -d "{\"spec\":$bad_mail}")
grep -q valid_email_domain /tmp/e2e-mail.json && [ "$code" = 400 ] && ok "disallowed e-mail domain -> 400 valid_email_domain" || bad "email domain" "$code $(head -c 200 /tmp/e2e-mail.json)"

# 8. tracker lists the generation with its GitHub location
t=$(curl -s $B/api/tracker | jq_ "[r['repo_name'] for r in d['records']][:5]")
case "$t" in *"$repo"*) ok "tracker lists $repo";; *) bad "tracker" "$t";; esac
loc=$(curl -s $B/api/tracker | jq_ "next((r.get('target_mode') or '')+'|'+(r.get('github_url') or '') for r in d['records'] if r['repo_name']=='$repo')")
case "$loc" in "subfolder|"*"/tree/main/$repo") ok "registry records where $repo was published";; *) bad "registry location" "$loc";; esac

# 9. cleanup rejects invalid names and unknown repositories (the deleting path is not run by this suite)
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/tracker/.hidden)
[ "$code" = 400 ] && ok "cleanup rejects an invalid repository name (400)" || bad "cleanup invalid name" "$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/tracker/not-generated-xyz)
[ "$code" = 404 ] && ok "cleanup of an unknown repository -> 404" || bad "cleanup unknown repository" "$code"

# 10. MCP: generate_code takes target_mode; the spec generated above is answered from the registry, not published again
M=http://localhost:8081/mcp
mcp() {  # mcp <method> <params>: one JSON-RPC call in a new MCP session
  local ct='Content-Type: application/json' ac='Accept: application/json, text/event-stream' sid
  sid=$(curl -s -D - -o /dev/null -H "$ct" -H "$ac" -X POST $M -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
    | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r')
  curl -s -o /dev/null -H "$ct" -H "$ac" -H "Mcp-Session-Id: $sid" -X POST $M -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s -H "$ct" -H "$ac" -H "Mcp-Session-Id: $sid" -X POST $M -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$1\",\"params\":$2}" \
    | sed -n 's/^data: //p;/^{/p' | head -1
}
tm=$(mcp tools/list '{}' | jq_ "next(t for t in d['result']['tools'] if t['name']=='generate_code')['inputSchema']['properties']['target_mode']['enum']")
[ "$tm" = "['subfolder', 'newRepo']" ] && ok "MCP generate_code accepts target_mode" || bad "MCP target_mode" "$tm"
md=$(mcp tools/call "{\"name\":\"generate_code\",\"arguments\":{\"spec\":$spec,\"target_mode\":\"newRepo\"}}" \
  | jq_ "(lambda x: str(x.get('duplicate'))+'|'+x.get('target_mode',''))(json.loads(d['result']['content'][0]['text']))")
[ "$md" = "True|subfolder" ] && ok "MCP generate_code of a generated spec -> duplicate in its stored location" || bad "MCP duplicate" "$md"

echo; echo "$P passed, $F failed"
