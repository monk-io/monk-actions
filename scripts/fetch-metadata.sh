#!/bin/sh
set -e

# Fetch capsule metadata (monkcode, JIT tokens, registry credentials) and
# write each to $GITHUB_OUTPUT so downstream jobs/actions can consume them.
#
# Sensitive outputs are double-base64'd: GitHub masks secret values found in
# logs, but masking a base64-of-masked-value preserves the secret across step
# boundaries while still being safe in the GITHUB_OUTPUT file. Consumers
# decode `echo "$VAR_B64" | base64 -di | base64 -di`.
#
# Required env: ENVIRONMENT_NAME, MONK_CAPSULE_TOKEN, MONK_AUTH_SERVICE_URL,
#               MONK_SUBSCRIPTION_API_BASE, MONK_API_PREFIX, MONK_PROJECT_SLUG
# Optional env: TARGET_CLUSTER_TOKEN (cluster-mode service token; preferred
#               over JIT minting when present), MONK_ORG_SLUG

export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

for var in ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_AUTH_SERVICE_URL MONK_SUBSCRIPTION_API_BASE MONK_API_PREFIX MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        echo "::error::$var is required"
        exit 1
    fi
done

# Step 1: Retrieve monkcode from backend
echo "Retrieving environment metadata for: $ENVIRONMENT_NAME"
HTTP_CODE=$(curl -s -o /tmp/env_data.json -w "%{http_code}" \
    "$MONK_SUBSCRIPTION_API_BASE/$MONK_API_PREFIX/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "Authorization: Bearer $MONK_CAPSULE_TOKEN")
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "::error::Failed to retrieve environment metadata (HTTP $HTTP_CODE)"
    cat /tmp/env_data.json 2>/dev/null || true
    exit 1
fi
echo "Environment metadata retrieved (HTTP $HTTP_CODE)"
MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_data.json)
if [ -z "$MONKCODE" ]; then
    echo "::error::Monkcode not found in environment response"
    echo "Response keys: $(jq -r 'keys' /tmp/env_data.json 2>/dev/null || echo 'parse error')"
    exit 1
fi
echo "Monkcode retrieved successfully"
echo "::add-mask::$MONKCODE"
echo "monkcode=$(echo -n "$MONKCODE" | base64 -w0 | base64 -w0)" >> "$GITHUB_OUTPUT"

# Step 2: Obtain CLI token for registry retrieval.
# Prefer service token (cluster-issued) over JIT-minted token.
TARGET_CLUSTER_TOKEN="${TARGET_CLUSTER_TOKEN:-}"
if [ -n "$TARGET_CLUSTER_TOKEN" ]; then
    echo "Using service token for cluster authentication."
    MONK_JIT_CLI_TOKEN="$TARGET_CLUSTER_TOKEN"
else
    echo "Minting JIT CLI token..."
    if ! JIT_RESPONSE=$(curl -sf -X POST "$MONK_AUTH_SERVICE_URL/api-keys" \
            -H "Authorization: Bearer $MONK_CAPSULE_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"fetch-meta-$ENVIRONMENT_NAME\",\"permissions\":[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\",\"manage:/projects/$MONK_PROJECT_SLUG/secrets/**\",\"manage:/projects/$MONK_PROJECT_SLUG/registry/**\"],\"expires_in_minutes\":30}"); then
        echo "::error::Failed to mint JIT CLI token (HTTP error)"
        exit 1
    fi
    MONK_JIT_CLI_TOKEN=$(echo "$JIT_RESPONSE" | jq -r '.jwt // empty')
    if [ -z "$MONK_JIT_CLI_TOKEN" ]; then
        echo "::error::Failed to mint JIT CLI token (empty response)"
        exit 1
    fi
fi
echo "::add-mask::$MONK_JIT_CLI_TOKEN"
echo "monk_jit_cli_token=$(echo -n "$MONK_JIT_CLI_TOKEN" | base64 -w0 | base64 -w0)" >> "$GITHUB_OUTPUT"

# Step 2.1: Mint short-lived JIT token for capsule metadata PATCH calls
echo "Minting metadata JIT token..."
if ! METADATA_JIT_RESPONSE=$(curl -sf -X POST "$MONK_AUTH_SERVICE_URL/api-keys" \
        -H "Authorization: Bearer $MONK_CAPSULE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"metadata-$ENVIRONMENT_NAME\",\"permissions\":[\"manage:/projects/$MONK_PROJECT_SLUG/environments/**\"],\"expires_in_minutes\":30}"); then
    echo "::error::Failed to mint metadata JIT token (HTTP error)"
    exit 1
fi
MONK_CAPSULE_METADATA_JIT_TOKEN=$(echo "$METADATA_JIT_RESPONSE" | jq -r '.jwt // empty')
if [ -z "$MONK_CAPSULE_METADATA_JIT_TOKEN" ]; then
    echo "::error::Failed to mint metadata JIT token (empty response)"
    exit 1
fi
echo "::add-mask::$MONK_CAPSULE_METADATA_JIT_TOKEN"
echo "capsule_metadata_jit_token=$(echo -n "$MONK_CAPSULE_METADATA_JIT_TOKEN" | base64 -w0 | base64 -w0)" >> "$GITHUB_OUTPUT"

# Step 3: Retrieve registry credentials from cluster secrets via monk CLI
export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"
export MONK_SOCKET="monkcode://$MONKCODE"
echo "Fetching registry credentials from cluster secrets..."
if ! REGISTRY_JSON=$(monk --json secrets get -r system/registry registry-auth 2>&1); then
    echo "::error::monk secrets get failed"
    echo "Output: $REGISTRY_JSON"
    exit 1
fi
echo "Registry secret response length: ${#REGISTRY_JSON}"
REGISTRY_ADDRESS=$(echo "$REGISTRY_JSON" | jq -r '.message // empty' | jq -r '.address // empty')
REGISTRY_USERNAME=$(echo "$REGISTRY_JSON" | jq -r '.message // empty' | jq -r '.username // empty')
REGISTRY_PASSWORD=$(echo "$REGISTRY_JSON" | jq -r '.message // empty' | jq -r '.password // empty')

if [ -z "$REGISTRY_ADDRESS" ] || [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    echo "::error::Failed to parse registry credentials from cluster secrets"
    echo "Address: ${REGISTRY_ADDRESS:-(empty)}, Username: ${REGISTRY_USERNAME:-(empty)}, Password set: $([ -n "$REGISTRY_PASSWORD" ] && echo yes || echo no)"
    echo "Raw jq parse of .message: $(echo "$REGISTRY_JSON" | jq -r '.message // empty' 2>&1 | head -c 200)"
    exit 1
fi
echo "Registry credentials retrieved: $REGISTRY_ADDRESS"
echo "::add-mask::$REGISTRY_PASSWORD"
echo "registry_address=$REGISTRY_ADDRESS" >> "$GITHUB_OUTPUT"
echo "registry_username=$REGISTRY_USERNAME" >> "$GITHUB_OUTPUT"
echo "registry_password=$(echo -n "$REGISTRY_PASSWORD" | base64 -w0 | base64 -w0)" >> "$GITHUB_OUTPUT"

# Pass-through context for downstream jobs
echo "subscription_api_base=$MONK_SUBSCRIPTION_API_BASE" >> "$GITHUB_OUTPUT"
echo "org_slug=${MONK_ORG_SLUG:-}" >> "$GITHUB_OUTPUT"
echo "api_prefix=$MONK_API_PREFIX" >> "$GITHUB_OUTPUT"
echo "project_slug=$MONK_PROJECT_SLUG" >> "$GITHUB_OUTPUT"
