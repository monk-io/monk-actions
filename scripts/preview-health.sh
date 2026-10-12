#!/bin/sh
set +e

# Check that the preview actually answers before the deploy reports success.
#
# With HEALTH_CHECK_PATH set (e.g. /health), the deploy fails unless
# <preview-url><path> answers 2xx or 3xx within HEALTH_CHECK_TIMEOUT seconds
# (default 300), and it fails if no preview URL was found at all.
# Without it, the preview root is probed once the same way and a dead preview
# is reported as a warning, so workloads with no HTTP endpoint keep deploying.
#
# Reads the URL preview-url.sh left in /tmp/preview_url.

HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-300}"
PREVIEW_URL=$(cat /tmp/preview_url 2>/dev/null)

if [ -z "$PREVIEW_URL" ]; then
    if [ -n "$HEALTH_CHECK_PATH" ]; then
        echo "::error::No preview URL was found, so $HEALTH_CHECK_PATH could not be checked"
        exit 1
    fi
    exit 0
fi

# 2xx/3xx counts as healthy. 000 means no connection; 404 from an unrouted
# ingress, or 502/503/504 from a backend that is down, are not healthy.
probe() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null
}

if [ -z "$HEALTH_CHECK_PATH" ]; then
    CODE=$(probe "$PREVIEW_URL")
    case "$CODE" in
        2*|3*) echo "Preview answered $CODE: $PREVIEW_URL" ;;
        *) echo "::warning::Preview $PREVIEW_URL answered ${CODE:-nothing}. Set health-check-path on the deploy action to fail the run when the preview is down." ;;
    esac
    exit 0
fi

case "$HEALTH_CHECK_PATH" in
    /*) TARGET="${PREVIEW_URL%/}$HEALTH_CHECK_PATH" ;;
    *) TARGET="${PREVIEW_URL%/}/$HEALTH_CHECK_PATH" ;;
esac

echo "Waiting up to ${HEALTH_CHECK_TIMEOUT}s for $TARGET to answer..."
START=$(date +%s)
while :; do
    CODE=$(probe "$TARGET")
    case "$CODE" in
        2*|3*)
            echo "Preview is healthy ($CODE): $TARGET"
            exit 0
            ;;
    esac
    if [ $(( $(date +%s) - START )) -ge "$HEALTH_CHECK_TIMEOUT" ]; then
        echo "::error::Preview health check failed: $TARGET answered ${CODE:-nothing} for ${HEALTH_CHECK_TIMEOUT}s"
        exit 1
    fi
    sleep 10
done
