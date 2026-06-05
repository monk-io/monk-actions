#!/bin/sh
set -e

# fetch-metadata emits monkcode / service-token double-base64'd to survive
# GitHub's log masking across step boundaries. Decode here so the script sees
# plain values.
if [ -n "$MONKCODE_B64" ]; then
    MONKCODE=$(echo "$MONKCODE_B64" | base64 -di | base64 -di)
    echo "::add-mask::$MONKCODE"
    export MONKCODE
fi
if [ -n "$MONK_JIT_CLI_TOKEN_B64" ]; then
    MONK_SERVICE_TOKEN=$(echo "$MONK_JIT_CLI_TOKEN_B64" | base64 -di | base64 -di)
    echo "::add-mask::$MONK_SERVICE_TOKEN"
    export MONK_SERVICE_TOKEN
fi

/opt/monk-actions/scripts/dynenv-deploy.sh
DEPLOY_RC=$?

# Best-effort preview URL extraction. Never fails the action.
/opt/monk-actions/scripts/preview-url.sh || true

exit $DEPLOY_RC
