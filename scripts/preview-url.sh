#!/bin/sh
set +e

# Determine a preview URL for the deployed capsule, writing `url=<value>` to
# $GITHUB_OUTPUT when found. Best-effort — emits nothing (and exits 0) if a
# URL cannot be determined.
#
# Required env: MONKCODE, MONK_SERVICE_TOKEN, MONK_WORKLOAD
# Optional env: MONK_REPO (cluster mode)

export MONK_SOCKET="monkcode://$MONKCODE"
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true

PREVIEW_URL=""

# Prefer explicit workload namespace endpoints over peer node domain inference.
if [ -n "$MONK_WORKLOAD" ] && echo "$MONK_WORKLOAD" | grep -q '/'; then
    WORKLOAD_NAMESPACE="${MONK_WORKLOAD%/*}"
    MONK_REPO="${MONK_REPO:-}"
    if [ -n "$MONK_REPO" ]; then
        ENDPOINT_ENTITY="${MONK_REPO}/${WORKLOAD_NAMESPACE}/endpoints"
    else
        ENDPOINT_ENTITY="${WORKLOAD_NAMESPACE}/endpoints"
    fi
    if ENDPOINTS_JSON=$(monk --json --no-events describe "$ENDPOINT_ENTITY" 2>/tmp/endpoints_describe_err.log); then
        PREVIEW_URL=$(echo "$ENDPOINTS_JSON" | jq -r '
            [
              .Entities[]?.ResultState?.values?.entrypoint_url?,
              .data?.entrypoint_url?.v?,
              .entrypoint_url?
            ]
            | map(select(type == "string" and length > 0))
            | map(select(. != "nil" and . != "null" and . != "https://nil" and . != "http://nil"))
            | .[0] // empty
        ')
        if [ -n "$PREVIEW_URL" ]; then
            case "$PREVIEW_URL" in
                http://*|https://*) ;;
                *) PREVIEW_URL="https://$PREVIEW_URL" ;;
            esac
        fi
    else
        echo "::warning::Could not describe $ENDPOINT_ENTITY, falling back to peer domain"
    fi
fi

# Fallback for clusters where the endpoint resource is not populated yet.
if [ -z "$PREVIEW_URL" ]; then
    DOMAIN=$(monk cluster peers --json | jq -r '
        [.[] | select(.domain != "" and (.domain | endswith(".monk.local") | not) and (.tags == null or ((.tags | index("system")) == null)))][0].domain // empty
    ')
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(monk cluster peers --json | jq -r '
            [.[] | select(.domain != "" and (.domain | endswith(".monk.local") | not))][0].domain // empty
        ')
    fi
    if [ -n "$DOMAIN" ]; then
        PREVIEW_URL="https://$DOMAIN"
    fi
fi

if [ -n "$PREVIEW_URL" ]; then
    echo "url=$PREVIEW_URL" >> "$GITHUB_OUTPUT"
    echo "Preview URL: $PREVIEW_URL"
else
    echo "::warning::Could not determine preview URL from endpoints or peers"
fi
exit 0
