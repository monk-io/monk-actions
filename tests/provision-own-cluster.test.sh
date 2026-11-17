#!/bin/sh
# Provision runs against a real platform and cloud, so there is no harness for it here. This guards
# the one rule that keeps cleanup from destroying a cluster it did not create: ownClusterId is
# recorded only from the cluster this run created. Run: sh tests/provision-own-cluster.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/dynenv-provision.sh"
FAILS=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}

# Both payloads (update and create) send the recorded-own id, never the id of a reused cluster.
check "payloads send the own id" 2 "$(grep -c 'ownClusterId: \$ownClusterId,' "$SCRIPT")"
check "no payload sends whichever cluster was used" 0 "$(grep -c 'ownClusterId: \$clusterId' "$SCRIPT")"

# The own id is set once, from the cluster info a fresh create extracts, and starts empty.
check "starts empty" 1 "$(grep -c '^OWN_CLUSTER_ID=""$' "$SCRIPT")"
check "assigned once" 1 "$(grep -c 'OWN_CLUSTER_ID="\$CLUSTER_ID"' "$SCRIPT")"
check "assigned right after the created cluster's id is read" "OWN_CLUSTER_ID=\"\$CLUSTER_ID\"" \
    "$(grep -A1 "CLUSTER_ID=\$(echo \"\$CLUSTER_INFO\" | jq -r '.data.id')" "$SCRIPT" | tail -1 | sed 's/^ *//')"

[ "$FAILS" -eq 0 ]
