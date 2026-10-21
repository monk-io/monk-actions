#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Deploy${NC}\n"

# Validate required env vars
# MONKCODE and MONK_SERVICE_TOKEN are set by the entrypoint before invoking this script
for var in MONKCODE MONK_SERVICE_TOKEN MONK_WORKLOAD; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

# Modes:
#   cloud   — capsule on a per-branch cluster (scoped by environment variable)
#   cluster — capsule on a shared cluster (repo-namespaced, scoped secrets)
#   static  — plain CI/CD deploy to a fixed cluster, no capsule environment
CAPSULE_MODE="${CAPSULE_MODE:-cloud}"
if [ "$CAPSULE_MODE" != "static" ] && [ -z "$ENVIRONMENT_NAME" ]; then
    printf "${RED}Error: ENVIRONMENT_NAME is required in '$CAPSULE_MODE' mode${NC}\n"
    exit 1
fi
if [ "$CAPSULE_MODE" = "cluster" ]; then
    MONK_REPO="$ENVIRONMENT_NAME"
    MONK_TAG="${PEER_POOL_TAG:-capsule-pool}"
else
    MONK_REPO=""
    MONK_TAG="${BRANCH_TAG:-default}"
fi

# Configure Monk CLI for non-interactive CI usage
export MONK_SOCKET="monkcode://$MONKCODE"
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

if [ ! -f "MANIFEST" ]; then
    printf "${RED}Error: MANIFEST file not found${NC}\n"
    exit 1
fi

# Whether any template in the checkout mentions `capsule-host` (BusyBox grep has no --include).
uses_capsule_host() {
    find . -path ./.git -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) \
        -exec grep -l 'capsule-host' {} + 2>/dev/null | grep -q .
}

# <environment>.<domain of the first node in the pool>, or nothing when there is no such node or the
# environment isn't usable as a single lowercase DNS label.
capsule_host() {
    label=$(printf '%s' "$ENVIRONMENT_NAME" | tr 'A-Z' 'a-z')
    case "$label" in
        ""|-*|*-|*[!a-z0-9-]*) return 0 ;;
    esac
    [ "${#label}" -le 63 ] || return 0
    domain=$(monk --json cluster peers 2>/dev/null | jq -r --arg tag "$MONK_TAG" '
        [.[] | select(.domain != "" and (.domain | endswith(".monk.local") | not)
                      and .tags != null and (.tags | index($tag)) != null)][0].domain // empty
    ' 2>/dev/null)
    [ -n "$domain" ] || return 0
    printf '%s.%s' "$label" "$domain"
}

# When MONK_REPO is set (shared cluster), load under a dedicated repo namespace.
if [ -n "$MONK_REPO" ]; then
    printf "${GREEN}Loading MANIFEST into repo '$MONK_REPO'...${NC}\n"
    monk load --repo "$MONK_REPO" MANIFEST

    # Branches share the pool's node domain, so a project that declares `capsule-host` is told its
    # own host under it, <environment>.<node domain>, to route on (`host: <- $capsule-host`).
    # Only passed when the project mentions it: setting a variable it doesn't declare may fail.
    HOST_ARGS=""
    if uses_capsule_host; then
        CAPSULE_HOST=$(capsule_host)
        if [ -n "$CAPSULE_HOST" ]; then
            printf "${GREEN}Branch host: $CAPSULE_HOST${NC}\n"
            printf '%s' "$CAPSULE_HOST" > /tmp/capsule_host
            HOST_ARGS="-s capsule-host=$CAPSULE_HOST"
        else
            printf "${YELLOW}Warning: no node domain or a branch name that isn't a valid host label; capsule-host is left unset.${NC}\n"
        fi
    fi

    printf "${GREEN}Deploying workload $MONK_REPO/$MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    # shellcheck disable=SC2086
    monk update -t "$MONK_TAG" --repo "$MONK_REPO" --secret-scope "$MONK_REPO" \
        -s environment="$ENVIRONMENT_NAME" $HOST_ARGS "$MONK_REPO/$MONK_WORKLOAD"
elif [ "$CAPSULE_MODE" = "static" ]; then
    printf "${GREEN}Loading MANIFEST...${NC}\n"
    monk load MANIFEST

    printf "${GREEN}Deploying workload $MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" "$MONK_WORKLOAD"
else
    printf "${GREEN}Loading MANIFEST...${NC}\n"
    monk load MANIFEST

    printf "${GREEN}Deploying workload $MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" -s environment="$ENVIRONMENT_NAME" "$MONK_WORKLOAD"
fi

printf "${GREEN}Checking deployment status...${NC}\n"
monk ps

printf "${GREEN}Deployment completed successfully!${NC}\n"
