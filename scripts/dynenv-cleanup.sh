#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Cleanup${NC}\n"

# Validate required env vars
for var in CLUSTER_NAME ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_AUTH_SERVICE_URL MONK_API_PREFIX MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

AUTH_HEADER="Authorization: Bearer $MONK_CAPSULE_TOKEN"
CAPSULE_DELETE_RECORDS="${CAPSULE_DELETE_RECORDS:-false}"

# Mint a short-lived JIT CLI token from the capsule master token
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

# Configure Monk CLI for non-interactive CI usage
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

printf "${GREEN}Cleaning up environment: $ENVIRONMENT_NAME (cluster: $CLUSTER_NAME, delete records: $CAPSULE_DELETE_RECORDS)${NC}\n"

# ============================================================================
# Step 1: Retrieve environment metadata from backend
# ============================================================================
printf "${GREEN}Retrieving environment metadata...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" \
    "$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "$AUTH_HEADER")

if [ "$HTTP_CODE" = "404" ]; then
    printf "${YELLOW}Environment not found (already cleaned up). Exiting.${NC}\n"
    exit 0
fi

if [ "$HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to retrieve environment (HTTP $HTTP_CODE)${NC}\n"
    cat /tmp/env_response.json 2>/dev/null || true
    exit 1
fi

MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_response.json)
CLUSTER_ID=$(jq -r '.cluster.clusterId // empty' /tmp/env_response.json)

# Capsule status is written once the outcome is known: "destroyed" after the
# cluster and records are gone, "failed" (with the reason) if any step fails,
# so a capsule whose machine is still running is never shown as destroyed.
ENV_URL="$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME"
set_capsule_status() {
    NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "$1" = "destroyed" ]; then
        PAYLOAD=$(jq -n --arg branch "$ENVIRONMENT_NAME" --arg now "$NOW_UTC" \
            '{settings:{capsule:{source:"dynenv",branch:$branch,status:"destroyed",lastDestroyedAt:$now,lastError:null,updatedAt:$now}}}')
    else
        PAYLOAD=$(jq -n --arg branch "$ENVIRONMENT_NAME" --arg now "$NOW_UTC" --arg err "$2" \
            '{settings:{capsule:{source:"dynenv",branch:$branch,status:"failed",lastError:$err,updatedAt:$now}}}')
    fi
    curl -sf -X PATCH "$ENV_URL" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" > /dev/null 2>&1 || true
}
on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        set_capsule_status failed "Destroy failed: the cluster may still be running. Re-run destroy or delete it from Monk."
    fi
}
trap on_exit EXIT

# True once the cluster has refused a fresh connection 3 times in a row.
cluster_gone() {
    misses=0
    tries=0
    while [ "$tries" -lt 12 ]; do
        tries=$((tries + 1))
        if MONK_SOCKET="monkcode://$MONKCODE" monk --json cluster peers >/dev/null 2>&1; then
            misses=0
        else
            misses=$((misses + 1))
            if [ "$misses" -ge 3 ]; then return 0; fi
        fi
        sleep 15
    done
    return 1
}

if [ -z "$MONKCODE" ]; then
    printf "${YELLOW}No cluster linked to environment. Cleaning up backend records only.${NC}\n"
else
    # ============================================================================
    # Step 2: Nuke the cluster
    # ============================================================================
    # First through monkcode:// with no local daemon, which is how Monk's own
    # cluster delete does it. Joining as a peer from the runner fails its
    # "check user credentials" step (ENG-908), so join-then-nuke is only the
    # fallback. Either way the cluster counts as gone only once it stops
    # answering: the nuke's own stream breaks when the node it talks to dies,
    # so its exit code alone says nothing.
    printf "${GREEN}Minting JIT CLI token for cleanup...${NC}\n"
    CLI_PERMS="[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\"]"
    MONK_JIT_CLI_TOKEN=$(mint_jit_token "$CLI_PERMS" "cleanup-$CLUSTER_NAME" 60)
    if [ -z "$MONK_JIT_CLI_TOKEN" ] || [ "$MONK_JIT_CLI_TOKEN" = "null" ]; then
        printf "${RED}Error: JIT CLI token mint returned empty${NC}\n"
        exit 1
    fi
    export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"

    printf "${GREEN}Nuking cluster $CLUSTER_NAME via monkcode...${NC}\n"
    MONK_SOCKET="monkcode://$MONKCODE" monk cluster nuke --force --remove-volumes --remove-snapshots \
        || printf "${YELLOW}The nuke command exited with an error; checking whether the cluster is gone...${NC}\n"
    if cluster_gone; then
        printf "${GREEN}Cluster nuked.${NC}\n"
        NUKED=true
    else
        printf "${YELLOW}The cluster still answers. Retrying through a local daemon joined to it...${NC}\n"
        NUKED=false
    fi
fi

if [ -n "$MONKCODE" ] && [ "$NUKED" != "true" ]; then
    printf "${GREEN}Starting local Monk daemon...${NC}\n"
    monkd > /tmp/monkd.log 2>&1 &
    printf "${GREEN}Waiting for daemon to initialize (up to 60s)...${NC}\n"
    MONK_WAIT_ELAPSED=0
    while [ $MONK_WAIT_ELAPSED -lt 60 ]; do
        if monk --no-interactive --nofancy --nocolor --json version > /dev/null 2>&1; then
            printf "${GREEN}Daemon responded after ${MONK_WAIT_ELAPSED}s.${NC}\n"
            break
        fi
        sleep 2
        MONK_WAIT_ELAPSED=$((MONK_WAIT_ELAPSED + 2))
    done
    if [ $MONK_WAIT_ELAPSED -ge 60 ]; then
        printf "${RED}Daemon failed to start within 60s. Log:${NC}\n"
        cat /tmp/monkd.log 2>/dev/null || true
        exit 1
    fi
    sleep 5

    printf "${GREEN}Joining cluster via monkcode...${NC}\n"
    monk cluster join --monkcode "$MONKCODE" --local-name "cleanup-runner-$$"

    printf "${GREEN}Nuking cluster: $CLUSTER_NAME...${NC}\n"
    monk cluster nuke --force --remove-volumes --remove-snapshots || true
    if ! cluster_gone; then
        printf "${RED}Error: Cluster $CLUSTER_NAME still answers after the nuke.${NC}\n"
        exit 1
    fi
    printf "${GREEN}Cluster nuked.${NC}\n"
fi

# The cluster is gone (or there was none); record cleanup below is best-effort.
set_capsule_status destroyed

# ============================================================================
# Step 3: Clean up backend records
# Delete cluster first (while it still has project_id for permission checks),
# then unlink from environment, then delete environment.
# ============================================================================
printf "${GREEN}Cleaning up backend records...${NC}\n"

# Calls one backend DELETE and says what came back when it isn't 2xx, rather
# than `curl -f` swallowing the reason.
backend_delete() {
    label="$1"; url="$2"
    code=$(curl -s -o /tmp/backend_delete.json -w "%{http_code}" -X DELETE "$url" -H "$AUTH_HEADER") || code=000
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        printf "${YELLOW}  Warning: $label failed (HTTP $code): %s${NC}\n" "$(head -c 300 /tmp/backend_delete.json 2>/dev/null)"
        return 1
    fi
}

# 3a. Unlink cluster from environment. First, so the cluster record is no
# longer referenced when it is deleted.
printf "  Unlinking cluster from environment...\n"
backend_delete "unlink (may already be unlinked)" \
    "$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME/cluster" || true

# 3b. Delete cluster record
if [ -n "$CLUSTER_ID" ]; then
    printf "  Deleting cluster record...\n"
    backend_delete "cluster record delete" \
        "$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/clusters/$CLUSTER_ID" || true
fi

# 3c. Delete environment only for permanent cleanup
if [ "$CAPSULE_DELETE_RECORDS" = "true" ]; then
    printf "  Deleting environment...\n"
    backend_delete "environment delete" \
        "$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" || true
else
    printf "  Keeping environment record for future reprovision.\n"
fi

printf "${GREEN}Cleanup completed successfully.${NC}\n"
