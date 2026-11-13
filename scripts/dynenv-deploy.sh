#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Deploy${NC}\n"

. "$(dirname "$0")/image-tag.sh"
. "$(dirname "$0")/monk-json.sh"

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

# Whether a template the MANIFEST loads declares an `ingress-host` variable. Other YAML in the
# checkout, a mention in a comment, or a workflow doesn't count: passing a variable the template
# doesn't declare may fail the update.
uses_ingress_host() {
    manifest_templates . | while read -r file; do
        [ -f "$file" ] && grep -q -E '^[[:space:]]*ingress-host:' "$file" && echo yes
    done | grep -q yes
}

# <environment>.<domain of the system node>, or of any other node with a usable domain when the
# system node has none, or nothing when no node has one, its domain isn't a plain host name, or the
# environment isn't usable as a single lowercase DNS label. The system node is always there and its
# domain never changes, and every node's ingress serves every route, so the host stays the same as
# the pool grows or shrinks. Sorted, so a redeploy gets the same host whatever order the peers come in.
ingress_host() {
    label=$(printf '%s' "$ENVIRONMENT_NAME" | tr 'A-Z' 'a-z')
    case "$label" in
        ""|-*|*-|*[!a-z0-9-]*) return 0 ;;
    esac
    [ "${#label}" -le 63 ] || return 0
    domain=$(monk_peers_json 2>/dev/null | jq -r '
        [.[] | select((.domain // "") != "" and ((.domain // "") | endswith(".monk.local") | not))]
        | sort_by([((.tags // []) | index("system")) == null, .domain]) | .[0].domain // empty
    ' 2>/dev/null) || domain=""
    case "$domain" in
        ""|*[!A-Za-z0-9.-]*) return 0 ;;
    esac
    printf '%s.%s' "$label" "$domain"
}

# build-images pushed each image as <tag>-<IMAGE_SUFFIX>; point the templates at it before loading.
if [ -n "$IMAGE_SUFFIX" ]; then
    rewrite_templates_for_branch "$IMAGE_SUFFIX"
fi

# WORKLOAD_SECRETS (single-line NAME=value lines) holds this branch's own values, set over the shared
# ones provision seeded. An empty value means the branch has none, so it is skipped.
seed_workload_secrets() {
    [ -n "$WORKLOAD_SECRETS" ] || return 0
    while IFS= read -r line; do
        line=${line%"$(printf '\r')"}   # a value edited on Windows must not carry its line ending
        [ -z "$line" ] && continue
        case "$line" in
            *=*) ;;
            *) printf "${YELLOW}Warning: skipping a workload-secrets line that isn't NAME=value${NC}\n"; continue ;;
        esac
        KEY="${line%%=*}"
        VALUE="${line#*=}"
        case "$KEY" in
            ""|*[!A-Za-z0-9_-]*) printf "${YELLOW}Warning: skipping a workload-secrets line with an invalid name${NC}\n"; continue ;;
        esac
        [ -n "$VALUE" ] || continue
        # Both streams are dropped: a failure could echo its arguments, and so the value, into the log.
        if [ -n "$MONK_REPO" ]; then
            monk secrets add --scope "$MONK_REPO" "$KEY=$VALUE" > /dev/null 2>&1 || { printf "${RED}Error: could not set secret $KEY${NC}\n"; exit 1; }
        else
            monk secrets add -g "$KEY=$VALUE" > /dev/null 2>&1 || { printf "${RED}Error: could not set secret $KEY${NC}\n"; exit 1; }
        fi
        printf "${GREEN}Secret $KEY set from this branch's environment${NC}\n"
    done <<EOF
$WORKLOAD_SECRETS
EOF
}

# When MONK_REPO is set (shared cluster), load under a dedicated repo namespace.
if [ -n "$MONK_REPO" ]; then
    seed_workload_secrets
    printf "${GREEN}Loading MANIFEST into repo '$MONK_REPO'...${NC}\n"
    monk load --repo "$MONK_REPO" MANIFEST

    # Branches share the pool's node domain, so a project that uses an `ingress-host` variable is told
    # its own host under it, <environment>.<node domain>, to route on (`host: <- $ingress-host`).
    # Only passed when the project mentions it: setting a variable it doesn't declare may fail.
    set -- -s environment="$ENVIRONMENT_NAME"
    if uses_ingress_host; then
        INGRESS_HOST=$(ingress_host)
        if [ -n "$INGRESS_HOST" ]; then
            printf "${GREEN}Branch host: $INGRESS_HOST${NC}\n"
            printf '%s' "$INGRESS_HOST" > /tmp/ingress_host
            set -- "$@" -s "ingress-host=$INGRESS_HOST"
        else
            printf "${YELLOW}Warning: no node domain or a branch name that isn't a valid host label; ingress-host is left unset.${NC}\n"
        fi
    fi

    printf "${GREEN}Deploying workload $MONK_REPO/$MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" --repo "$MONK_REPO" --secret-scope "$MONK_REPO" \
        "$@" "$MONK_REPO/$MONK_WORKLOAD"
elif [ "$CAPSULE_MODE" = "static" ]; then
    [ -z "$WORKLOAD_SECRETS" ] || printf "${YELLOW}Warning: workload-secrets is only used for capsules; ignored in static mode.${NC}\n"
    printf "${GREEN}Loading MANIFEST...${NC}\n"
    monk load MANIFEST

    printf "${GREEN}Deploying workload $MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" "$MONK_WORKLOAD"
else
    seed_workload_secrets
    printf "${GREEN}Loading MANIFEST...${NC}\n"
    monk load MANIFEST

    printf "${GREEN}Deploying workload $MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" -s environment="$ENVIRONMENT_NAME" "$MONK_WORKLOAD"
fi

printf "${GREEN}Checking deployment status...${NC}\n"
monk ps

printf "${GREEN}Deployment completed successfully!${NC}\n"
