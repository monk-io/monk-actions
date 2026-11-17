#!/bin/sh
# Provision runs against a real platform and cloud, so there is no harness for it here. This runs the
# two settings payloads it builds (the update and the create one), cut out of the script, and checks
# the one rule that keeps cleanup from destroying a cluster it did not create: ownClusterId is sent
# only when this run created the cluster. Run: sh tests/provision-own-cluster.test.sh (needs jq).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/dynenv-provision.sh"
FAILS=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}

# the assignment of one payload variable, as written in the script
block() { awk -v name="$1" '$0 ~ "^[ ]*" name "=\\$\\(jq -n" {f=1} f {print} f && /}'"'"'\)$/ {exit}' "$SCRIPT"; }

export BRANCH_NAME=feat GITHUB_REPOSITORY=o/r GITHUB_ENVIRONMENT=capsule-feat NOW_UTC=now \
    ENVIRONMENT_NAME=feat CLUSTER_ID=reused-or-new MONK_PROJECT_SLUG=p
for name in CAPSULE_SETTINGS_PAYLOAD ENV_CREATE_PAYLOAD; do
    code=$(block "$name")
    check "$name: found in the script" 1 "$([ -n "$code" ] && echo 1 || echo 0)"

    OWN_CLUSTER_ID="" eval "$code"
    eval "out=\$$name"
    check "$name: no cluster created, no own id sent" null "$(printf '%s' "$out" | jq -c '.settings.capsule.ownClusterId')"
    check "$name: the rest of the settings still sent" cloud "$(printf '%s' "$out" | jq -r '.settings.capsule.mode')"

    OWN_CLUSTER_ID="created-here" eval "$code"
    eval "out=\$$name"
    check "$name: a created cluster is sent as the own id" created-here "$(printf '%s' "$out" | jq -r '.settings.capsule.ownClusterId')"
done

# the id is recorded only after the created cluster's info proved sound, and is never the literal null
assign=$(grep -n 'OWN_CLUSTER_ID="\$CLUSTER_ID"' "$SCRIPT" | cut -d: -f1)
proved=$(grep -n 'Failed to extract monkcode from cluster info' "$SCRIPT" | cut -d: -f1)
check "own id assigned once" 1 "$(printf '%s\n' "$assign" | grep -c .)"
check "own id assigned after the cluster info was checked" 1 "$([ "$assign" -gt "$proved" ] && echo 1 || echo 0)"
check "own id never the literal null" 1 "$(grep -c '"\$CLUSTER_ID" != "null"' "$SCRIPT")"

[ "$FAILS" -eq 0 ]
