#!/bin/sh
set -e

# fetch-metadata emits the registry password double-base64'd. Decode and mask
# before invoking the build script.
if [ -n "$REGISTRY_PASSWORD_B64" ]; then
    REGISTRY_PASSWORD=$(echo "$REGISTRY_PASSWORD_B64" | base64 -di | base64 -di)
    echo "::add-mask::$REGISTRY_PASSWORD"
    export REGISTRY_PASSWORD
fi

if [ -z "$REGISTRY_ADDRESS" ] || [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    echo "::error::Registry credentials are required for Monk Capsules"
    echo "REGISTRY_ADDRESS=${REGISTRY_ADDRESS:-(missing)}"
    echo "REGISTRY_USERNAME=${REGISTRY_USERNAME:-(missing)}"
    echo "REGISTRY_PASSWORD set: $([ -n "$REGISTRY_PASSWORD" ] && echo yes || echo no)"
    exit 1
fi
echo "Registry credentials validated: $REGISTRY_ADDRESS"

exec /opt/monk-actions/scripts/build-images.sh
