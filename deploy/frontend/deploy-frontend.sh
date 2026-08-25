#!/bin/sh

set -eu

HELPER=${AIFOO_DEPLOY_HELPER:-/usr/local/libexec/aifoo-deploy-helper}
IMAGE=${1:-}

if ! printf '%s' "$IMAGE" | grep -Eq \
  '^ghcr\.io/jayhome137/sub2api-frontend@sha256:[0-9a-f]{64}$'; then
  echo "Usage: $0 ghcr.io/jayhome137/sub2api-frontend@sha256:<64 lowercase hex>" >&2
  exit 1
fi

exec "$HELPER" frontend-activate "$IMAGE"
