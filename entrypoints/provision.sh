#!/bin/sh
set -e

. /opt/monk-actions/entrypoints/_common.sh

# Cloud-provider creds arrive as a multiline KEY=value bag; the provision
# script expects them as individual env vars (DO_API_TOKEN, AWS_ACCESS_KEY_ID,
# AZURE_SDK_AUTH, GCP_SERVICE_ACCOUNT_KEY, etc.).
load_kv_bag "$CLOUD_CREDENTIALS"

CAPSULE_MODE="${CAPSULE_MODE:-cloud}"
case "$CAPSULE_MODE" in
    cluster)
        exec /opt/monk-actions/scripts/dynenv-provision-on-cluster.sh
        ;;
    cloud|"")
        exec /opt/monk-actions/scripts/dynenv-provision.sh
        ;;
    *)
        echo "Error: unknown CAPSULE_MODE='$CAPSULE_MODE' (expected 'cloud' or 'cluster')" >&2
        exit 1
        ;;
esac
