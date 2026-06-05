#!/bin/sh
set -e

CAPSULE_MODE="${CAPSULE_MODE:-cloud}"
case "$CAPSULE_MODE" in
    cluster)
        exec /opt/monk-actions/scripts/dynenv-cleanup-on-cluster.sh
        ;;
    cloud|"")
        exec /opt/monk-actions/scripts/dynenv-cleanup.sh
        ;;
    *)
        echo "Error: unknown CAPSULE_MODE='$CAPSULE_MODE' (expected 'cloud' or 'cluster')" >&2
        exit 1
        ;;
esac
