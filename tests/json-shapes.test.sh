#!/bin/sh
# Tests for scripts/monk-json.sh: the CLI's --json output is read the same in the Monk 4 envelope
# (taken from the Monk repo's own test fixtures) and in Monk 3's bare shapes. Run:
# sh tests/json-shapes.test.sh (also under busybox: the actions image is Alpine).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../scripts/monk-json.sh"

FAILS=0
eq() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}

# ── peers
V4_PEERS='{"command":"cluster peers","data":{"items":[{"id":"a","name":"local","tags":[],"local":true,"publicIp":"10.0.0.2"},{"id":"b","name":"aws-1","tags":["web","system"],"domain":"shop.example.com","local":false},{"id":"c","name":"gcp-1","tags":["db"],"local":false}]},"ok":true,"type":"result","v":1}'
V3_PEERS='[{"id":"a","name":"local","tags":[],"local":true},{"id":"b","name":"aws-1","tags":["web","system"],"domain":"shop.example.com"},{"id":"c","name":"gcp-1","tags":["db"]}]'
names() { jq -r '[.[].name] | join(",")'; }
eq "peers, Monk 4 envelope"   "local,aws-1,gcp-1" "$(printf '%s' "$V4_PEERS" | monk_peers_array | names)"
eq "peers, Monk 3 array"      "local,aws-1,gcp-1" "$(printf '%s' "$V3_PEERS" | monk_peers_array | names)"
eq "peers, Monk 4 none"       "[]" "$(printf '%s' '{"command":"cluster peers","data":{"items":[]},"ok":true,"type":"result","v":1}' | monk_peers_array)"
eq "peers, Monk 4 no items"   "[]" "$(printf '%s' '{"command":"cluster peers","data":{},"ok":true,"type":"result","v":1}' | monk_peers_array)"

# The filters the scripts run on the array: a peer without a domain key (Monk 4 leaves it out when
# empty) is not a domain.
domain_of() { jq -r '[.[] | select((.domain // "") != "" and (.domain | endswith(".monk.local") | not))][0].domain // empty'; }
eq "domain, Monk 4"           "shop.example.com" "$(printf '%s' "$V4_PEERS" | monk_peers_array | domain_of)"
eq "domain, Monk 3"           "shop.example.com" "$(printf '%s' "$V3_PEERS" | monk_peers_array | domain_of)"
eq "domain, none"             "" "$(printf '%s' '[{"id":"a","name":"local"}]' | monk_peers_array | domain_of)"

# monk_peers_json runs the CLI: a stub on PATH answers, or fails.
T=$(mktemp -d)
cat > "$T/monk" <<'S'
#!/bin/sh
[ "${STUB_FAIL:-}" = "1" ] && { echo "boom" >&2; exit 1; }
printf '%s' "$STUB_OUT"
S
chmod +x "$T/monk"
PATH="$T:$PATH"
export STUB_OUT="$V4_PEERS"
eq "peers_json, Monk 4"       "local,aws-1,gcp-1" "$(monk_peers_json | names)"
export STUB_OUT="$V3_PEERS"
eq "peers_json, Monk 3"       "local,aws-1,gcp-1" "$(monk_peers_json | names)"
if STUB_FAIL=1 monk_peers_json > /dev/null 2>&1; then echo "FAIL peers_json hides a CLI failure"; FAILS=$((FAILS + 1)); else echo "ok   peers_json fails when the CLI fails"; fi
rm -rf "$T"

# ── users
V4_USERS='{"command":"users list","data":{"items":[{"email":"owner@example.com","role":"owner"},{"email":"ann@example.com","role":"user"}]},"ok":true,"type":"result","v":1}'
V3_USERS='{"users":[{"email":"owner@example.com","role":"owner"},{"email":"ann@example.com","role":"user"}]}'
V3_USERS_ARRAY='[{"Email":"owner@example.com","Role":"owner"},{"Email":"ann@example.com","Role":"user"}]'
emails() { jq -r '[.[] | (.email // .Email)] | join(",")'; }
eq "users, Monk 4 envelope"   "owner@example.com,ann@example.com" "$(printf '%s' "$V4_USERS" | monk_users_array | emails)"
eq "users, Monk 3 object"     "owner@example.com,ann@example.com" "$(printf '%s' "$V3_USERS" | monk_users_array | emails)"
eq "users, Monk 3 array"      "owner@example.com,ann@example.com" "$(printf '%s' "$V3_USERS_ARRAY" | monk_users_array | emails)"
eq "users, nothing"           "[]" "$(printf '%s' '{}' | monk_users_array)"

# ── plugins
V4_PLUGINS='{"command":"plugins list","data":{"items":[{"name":"autoscaler","enabled":false},{"name":"ingress","enabled":true}]},"ok":true,"type":"result","v":1}'
V4_PLUGINS_OFF='{"command":"plugins list","data":{"items":[{"name":"ingress","enabled":false}]},"ok":true,"type":"result","v":1}'
V3_PLUGINS='{"data":{"plugins":[{"name":"ingress","enabled":true}]}}'
yn() { if printf '%s' "$1" | monk_plugin_enabled ingress; then echo yes; else echo no; fi; }
eq "plugins, Monk 4 enabled"  "yes" "$(yn "$V4_PLUGINS")"
eq "plugins, Monk 4 disabled" "no"  "$(yn "$V4_PLUGINS_OFF")"
eq "plugins, Monk 3 enabled"  "yes" "$(yn "$V3_PLUGINS")"
eq "plugins, empty output"    "no"  "$(yn "")"
eq "plugins, not JSON"        "no"  "$(yn "error: daemon unreachable")"

# ── secrets
REG='{"address":"reg.example.com","username":"u","password":"p"}'
V4_SECRET=$(jq -cn --arg v "$REG" '{command:"secrets get",data:{name:"registry-auth",kind:"runnable",value:$v},ok:true,type:"result",v:1}')
V3_SECRET=$(jq -cn --arg v "$REG" '{message:$v}')
eq "secret, Monk 4"           "$REG" "$(printf '%s' "$V4_SECRET" | monk_secret_value)"
eq "secret, Monk 3"           "$REG" "$(printf '%s' "$V3_SECRET" | monk_secret_value)"
eq "secret, Monk 4 address"   "reg.example.com" "$(printf '%s' "$V4_SECRET" | monk_secret_value | jq -r '.address')"
eq "secret, missing"          "" "$(printf '%s' '{"data":{}}' | monk_secret_value)"

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
