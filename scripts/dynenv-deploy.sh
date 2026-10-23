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

# The template files a MANIFEST loads: its LOAD files, and those of the sub-MANIFESTs named by
# DIR/DIRS, each relative to the MANIFEST that names it. A missing sub-MANIFEST adds nothing.
# $2 is the nesting depth, which stops a DIRS loop.
manifest_templates() {
    [ -f "$1/MANIFEST" ] || return 0
    sed 's/#.*//' "$1/MANIFEST" | awk 'toupper($1) == "LOAD" { for (i = 2; i <= NF; i++) print $i }' |
        while read -r file; do printf '%s/%s\n' "$1" "$file"; done
    [ "${2:-0}" -lt 8 ] || return 0
    sed 's/#.*//' "$1/MANIFEST" |
        awk 'toupper($1) == "DIR" || toupper($1) == "DIRS" { for (i = 2; i <= NF; i++) print $i }' |
        while read -r sub; do manifest_templates "$1/$sub" $((${2:-0} + 1)); done
}

# Whether a template the MANIFEST loads declares an `ingress-host` variable. Other YAML in the
# checkout, a mention in a comment, or a workflow doesn't count: passing a variable the template
# doesn't declare may fail the update.
uses_ingress_host() {
    manifest_templates . | while read -r file; do
        [ -f "$file" ] && grep -q -E '^[[:space:]]*ingress-host:' "$file" && echo yes
    done | grep -q yes
}

# <environment>.<domain of the pool node that sorts first by domain>, or nothing when there is no
# such node, its domain isn't a plain host name, or the environment isn't usable as a single
# lowercase DNS label. Sorted, so a redeploy gets the same host whatever order the peers come in.
ingress_host() {
    label=$(printf '%s' "$ENVIRONMENT_NAME" | tr 'A-Z' 'a-z')
    case "$label" in
        ""|-*|*-|*[!a-z0-9-]*) return 0 ;;
    esac
    [ "${#label}" -le 63 ] || return 0
    domain=$(monk --json cluster peers 2>/dev/null | jq -r --arg tag "$MONK_TAG" '
        [.[] | select(.domain != "" and (.domain | endswith(".monk.local") | not)
                      and .tags != null and (.tags | index($tag)) != null)]
        | sort_by(.domain) | .[0].domain // empty
    ' 2>/dev/null) || domain=""
    case "$domain" in
        ""|*[!A-Za-z0-9.-]*) return 0 ;;
    esac
    printf '%s.%s' "$label" "$domain"
}

# When MONK_REPO is set (shared cluster), load under a dedicated repo namespace.
if [ -n "$MONK_REPO" ]; then
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
