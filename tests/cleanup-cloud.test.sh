#!/bin/sh
# Runs scripts/dynenv-cleanup.sh (cloud mode) against stub `curl`, `monk` and `sleep`, to check what
# it does to the cluster an environment is linked to. Run: sh tests/cleanup-cloud.test.sh (needs jq).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/dynenv-cleanup.sh"
FAILS=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}

T=$(mktemp -d)
mkdir "$T/bin"
export STUB_LOG="$T/log" ENV_JSON="$T/env.json"

# curl: records "METHOD URL", answers by URL, honours -o and -w '%{http_code}'.
cat > "$T/bin/curl" <<'S'
#!/bin/sh
out=""; fmt=""; method="GET"; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -w) fmt="$2"; shift ;;
        -X) method="$2"; shift ;;
        -H|-d) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
echo "$method $url" >> "$STUB_LOG"
code=200; body='{}'
case "$method $url" in
    "POST "*/api-keys) body='{"jwt":"jit-token"}' ;;
    "GET "*/environments/*) body=$(cat "$ENV_JSON") ;;
    "DELETE "*/clusters/*) code="${DELETE_CLUSTER_CODE:-204}"; body='' ;;
    "DELETE "*) code=204; body='' ;;
esac
[ -z "$out" ] || printf '%s' "$body" > "$out"
[ -n "$out" ] || printf '%s' "$body"
case "$fmt" in *http_code*) printf '%s' "$code" ;; esac
case "$code" in 2??) exit 0 ;; *) exit 22 ;; esac
S

# monk: nuke and peers fail the way MONK_FAILURE says.
cat > "$T/bin/monk" <<'S'
#!/bin/sh
echo "monk $*" >> "$STUB_LOG"
case "$*" in
    *"cluster nuke"*|*"cluster peers"*)
        case "$MONK_FAILURE" in
            access) echo "FAILping monk error: [-32098] user auth0|x doesn't have access to the cluster" >&2 ;;
            *) echo "dial tcp 10.0.0.1:2138: connection refused" >&2 ;;
        esac
        exit 1 ;;
esac
exit 0
S
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/monkd"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

export CLUSTER_NAME=proj-feat ENVIRONMENT_NAME=feat MONK_CAPSULE_TOKEN=t \
    MONK_SUBSCRIPTION_API_BASE=https://api MONK_AUTH_SERVICE_URL=https://auth \
    MONK_API_PREFIX=orgs/o MONK_PROJECT_SLUG=p CAPSULE_DELETE_RECORDS=true

run() { # linked cluster name, failure kind
    : > "$STUB_LOG"
    printf '{"cluster":{"name":"%s","clusterId":"cid","monkcode":"mc"}}' "$1" > "$ENV_JSON"
    MONK_FAILURE="$2" sh "$SCRIPT" > "$T/out" 2>&1
    echo $?
}
called() { grep -c "$1" "$STUB_LOG"; }

# A cluster the environment is linked to but that isn't the capsule's own (a shared cluster that
# another mode's environments use) must not be nuked or deleted; the environment is still cleaned.
check "shared cluster: cleanup succeeds" 0 "$(run shared-cluster access)"
check "shared cluster: not nuked" 0 "$(called 'cluster nuke')"
check "shared cluster: platform record kept" 0 "$(called 'DELETE https://api/orgs/o/clusters/')"
check "shared cluster: environment unlinked and deleted" 2 "$(grep -c 'DELETE https://api/orgs/o/projects/p/environments/feat' "$STUB_LOG")"
check "shared cluster: says so" 1 "$(grep -c "Leaving that cluster running" "$T/out")"
check "shared cluster: annotated on the run" 1 "$(grep -c '^::warning title=Cluster left running::' "$T/out")"

# A link that doesn't say which cluster it is can't be shown to be the capsule's own.
printf '{"cluster":{"clusterId":"cid","monkcode":"mc"}}' > "$ENV_JSON"
: > "$STUB_LOG"; MONK_FAILURE=access sh "$SCRIPT" > "$T/out" 2>&1
check "unnamed cluster: not nuked, record kept" 00 "$(called 'cluster nuke')$(called 'DELETE https://api/orgs/o/clusters/')"

# The capsule's own cluster that refuses access is not gone: the record stays and cleanup fails.
rc=$(run proj-feat access)
check "own cluster, access refused: cleanup fails" 1 "$rc"
check "own cluster, access refused: not called gone" 0 "$(grep -c 'Cluster nuked' "$T/out")"
check "own cluster, access refused: platform record kept" 0 "$(called 'DELETE https://api/orgs/o/clusters/')"

# The capsule's own cluster that no longer answers is gone: its record is removed.
rc=$(run proj-feat refused)
check "own cluster, gone: cleanup succeeds" 0 "$rc"
check "own cluster, gone: platform record deleted" 1 "$(called 'DELETE https://api/orgs/o/clusters/cid')"

rm -rf "$T"
[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
