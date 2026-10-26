#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Cleanup on Existing Cluster${NC}\n"

# Validate required env vars
for var in ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_AUTH_SERVICE_URL MONK_API_PREFIX MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

MONK_WORKLOAD="${MONK_WORKLOAD:-}"
AUTH_HEADER="Authorization: Bearer $MONK_CAPSULE_TOKEN"
CAPSULE_DELETE_RECORDS="${CAPSULE_DELETE_RECORDS:-false}"
ENV_PATH="$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME"

# Mint a short-lived JIT CLI token
mint_jit_token() {
    local perms="$1"
    local name="${2:-jit-$$}"
    local ttl="${3:-60}"
    if ! JIT_RESPONSE=$(curl -sf -X POST "$MONK_AUTH_SERVICE_URL/api-keys" \
        -H "Authorization: Bearer $MONK_CAPSULE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"permissions\":$perms,\"expires_in_minutes\":$ttl}"); then
        printf "${RED}Error: Failed to mint JIT token${NC}\n" >&2
        return 1
    fi
    JIT_TOKEN=$(echo "$JIT_RESPONSE" | jq -r '.jwt // empty')
    if [ -z "$JIT_TOKEN" ]; then
        printf "${RED}Error: JIT token response did not include jwt${NC}\n" >&2
        return 1
    fi
    echo "$JIT_TOKEN"
}

export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

printf "${GREEN}Cleaning up capsule: $ENVIRONMENT_NAME${NC}\n"

# ============================================================================
# Step 1: Retrieve environment metadata to find cluster monkcode
# ============================================================================
printf "${GREEN}Retrieving environment metadata...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" "$ENV_PATH" -H "$AUTH_HEADER")
if [ "$HTTP_CODE" = "404" ]; then
    printf "${YELLOW}Environment not found (already cleaned up). Exiting.${NC}\n"
    exit 0
fi
if [ "$HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to retrieve environment (HTTP $HTTP_CODE)${NC}\n"
    exit 1
fi
MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_response.json)
CLUSTER_ID=$(jq -r '.cluster.clusterId // empty' /tmp/env_response.json)

# Status is written once the outcome is known (see dynenv-cleanup.sh).
set_capsule_status() {
    NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "$1" = "destroyed" ]; then
        PAYLOAD=$(jq -n --arg now "$NOW_UTC" \
            '{settings:{capsule:{source:"dynenv",status:"destroyed",lastDestroyedAt:$now,lastError:null,updatedAt:$now}}}')
    else
        PAYLOAD=$(jq -n --arg now "$NOW_UTC" --arg err "$2" \
            '{settings:{capsule:{source:"dynenv",status:"failed",lastError:$err,updatedAt:$now}}}')
    fi
    curl -sf -X PATCH "$ENV_PATH" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "$PAYLOAD" > /dev/null 2>&1 || true
}
on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        set_capsule_status failed "Destroy failed: the workload may still be running. Re-run destroy."
    fi
}
trap on_exit EXIT

if [ -z "$MONKCODE" ]; then
    printf "${YELLOW}No cluster linked. Cleaning up backend records only.${NC}\n"
else
    # ============================================================================
    # Step 2: Connect to cluster, stop workloads, clean up
    # ============================================================================
    TARGET_CLUSTER_TOKEN="${TARGET_CLUSTER_TOKEN:-}"
    if [ -n "$TARGET_CLUSTER_TOKEN" ]; then
        printf "${GREEN}Using service token for cluster authentication.${NC}\n"
        export MONK_SERVICE_TOKEN="$TARGET_CLUSTER_TOKEN"
    else
        printf "${GREEN}Minting JIT CLI token for cleanup...${NC}\n"
        CLI_PERMS="[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\",\"manage:/projects/$MONK_PROJECT_SLUG/secrets/**\"]"
        MONK_JIT_CLI_TOKEN=$(mint_jit_token "$CLI_PERMS" "cleanup-$ENVIRONMENT_NAME" 60)
        if [ -z "$MONK_JIT_CLI_TOKEN" ] || [ "$MONK_JIT_CLI_TOKEN" = "null" ]; then
            printf "${RED}Error: JIT CLI token mint returned empty${NC}\n"
            exit 1
        fi
        export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"
    fi
    export MONK_SOCKET="monkcode://$MONKCODE"

    # Delete workloads using fully qualified repo/workload path
    if [ -n "$MONK_WORKLOAD" ]; then
        printf "${GREEN}Deleting workload '$ENVIRONMENT_NAME/$MONK_WORKLOAD'...${NC}\n"
        # A failed delete stops the run: the environment is marked failed and keeps its cluster
        # link, so a re-run or the hourly sweep retries it. (Deleting an absent workload succeeds.)
        if ! monk delete --no-confirm --remove-volumes --remove-snapshots "$ENVIRONMENT_NAME/$MONK_WORKLOAD"; then
            printf "${RED}Error: deleting the workload failed; the capsule is kept so the cleanup can be retried${NC}\n"
            exit 1
        fi
        # The workload is gone by now; templates left loaded are replaced by the next load.
        printf "${GREEN}Unloading workload templates...${NC}\n"
        monk unload --repo "$ENVIRONMENT_NAME" --no-confirm "$ENVIRONMENT_NAME/$MONK_WORKLOAD" ||
            printf "${YELLOW}Warning: unload failed${NC}\n"
    fi

    # Remove scoped secrets — WORKLOAD_SECRETS is a multiline KEY=value bag; we only need the keys.
    # An absent key is fine; any other failure is reported after the rest were tried.
    if [ -n "$WORKLOAD_SECRETS" ]; then
        printf "${GREEN}Removing scoped secrets for '$ENVIRONMENT_NAME'...${NC}\n"
        SECRET_FAILED=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            KEY="${line%%=*}"
            [ -z "$KEY" ] && continue
            if ! SECRET_OUT=$(monk secrets remove --scope "$ENVIRONMENT_NAME" "$KEY" 2>&1); then
                case "$SECRET_OUT" in
                    *"not found in scope"*) printf "  Secret '$KEY' was already removed.\n" ;;
                    *)
                        printf "${RED}Error: failed to remove secret '$KEY': $SECRET_OUT${NC}\n"
                        SECRET_FAILED=1
                        ;;
                esac
            fi
        done <<EOF
$WORKLOAD_SECRETS
EOF
        if [ -n "$SECRET_FAILED" ]; then
            printf "${RED}Error: some scoped secrets were not removed; the capsule is kept so the cleanup can be retried${NC}\n"
            exit 1
        fi
    fi
fi

# ============================================================================
# Step 3: Clean up backend records (DO NOT delete cluster — it's shared)
# Only reached once the workload and its secrets are gone. A record already gone (404) is fine;
# any other failure stops the run, and the environment is marked failed and retried.
# ============================================================================
printf "${GREEN}Cleaning up backend records...${NC}\n"

api_delete() {
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$1" -H "$AUTH_HEADER") || CODE=000
    case "$CODE" in
        2??|404) return 0 ;;
    esac
    printf "${RED}Error: DELETE $2 failed (HTTP $CODE)${NC}\n"
    return 1
}

# Unlink cluster from environment
printf "  Unlinking cluster from environment...\n"
api_delete "$ENV_PATH/cluster" "the cluster link" || exit 1

# Delete environment record if permanent cleanup; otherwise keep it, marked destroyed
if [ "$CAPSULE_DELETE_RECORDS" = "true" ]; then
    printf "  Deleting environment record...\n"
    api_delete "$ENV_PATH" "the environment record" || exit 1
else
    set_capsule_status destroyed
    printf "  Keeping environment record for future reprovision.\n"
fi

printf "${GREEN}Cleanup completed successfully.${NC}\n"
