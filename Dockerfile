ARG MONK_CI_VERSION=latest
FROM monkreleases.azurecr.io/monk-ci:${MONK_CI_VERSION}

# Capsule scripts need curl, jq (likely already in monk-ci) and htpasswd for
# generating the per-cluster registry password hash.
RUN apk add --no-cache curl jq apache2-utils

COPY scripts/      /opt/monk-actions/scripts/
COPY entrypoints/  /opt/monk-actions/entrypoints/

RUN chmod +x /opt/monk-actions/scripts/*.sh /opt/monk-actions/entrypoints/*.sh

# Each action.yml overrides ENTRYPOINT; this default is just a safety net.
ENTRYPOINT ["/bin/sh", "-c", "echo 'monk-actions image — override entrypoint per action'; exit 1"]
