#!/bin/sh
set -e

# Credentials arrive one of two ways:
#  - Capsule flows: double-base64'd from fetch-metadata (survives GitHub's log
#    masking across step boundaries) — decoded here.
#  - Static CI/CD flows: plain MONKCODE / MONK_SERVICE_TOKEN env vars mapped
#    straight from repo secrets — used as-is.
# B64 variants take precedence when both are set.
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

# A deploy whose preview doesn't answer is not a success (see the script for
# when this fails the run and when it only warns).
/opt/monk-actions/scripts/preview-health.sh || exit 1

exit $DEPLOY_RC
