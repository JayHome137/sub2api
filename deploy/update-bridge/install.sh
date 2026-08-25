#!/bin/sh

set -eu

BRIDGE_BINARY=${1:-}
HELPER_BINARY=${2:-}
DEPLOY_USER=${3:-root}

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root" >&2
  exit 1
fi
for binary in "$BRIDGE_BINARY" "$HELPER_BINARY"; do
  if [ -z "$binary" ] || [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
    echo "Usage: $0 /path/to/aifoo-update-bridge /path/to/aifoo-deploy-helper [deploy-user]" >&2
    exit 1
  fi
done
if ! printf '%s' "$DEPLOY_USER" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]*$' \
  || ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "Deploy user does not exist or has an invalid name" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
install -d -o root -g root -m 0755 /usr/local/libexec
install -d -o root -g root -m 0700 /var/lib/aifoo-deploy-helper
install -d -o root -g root -m 0700 /var/lib/aifoo-deploy-helper/docker-config

for target in /usr/local/libexec/aifoo-update-bridge /usr/local/libexec/aifoo-deploy-helper; do
  if [ -f "$target" ]; then
    install -o root -g root -m 0755 "$target" "$target.previous"
  fi
done
if [ -f /etc/systemd/system/aifoo-update-bridge.service ]; then
  install -o root -g root -m 0644 \
    /etc/systemd/system/aifoo-update-bridge.service \
    /etc/systemd/system/aifoo-update-bridge.service.previous
fi

install -o root -g root -m 0755 "$BRIDGE_BINARY" /usr/local/libexec/aifoo-update-bridge
install -o root -g root -m 0755 "$HELPER_BINARY" /usr/local/libexec/aifoo-deploy-helper
install -o root -g root -m 0644 \
  "$SCRIPT_DIR/aifoo-update-bridge.service" \
  /etc/systemd/system/aifoo-update-bridge.service

if [ "$DEPLOY_USER" != root ]; then
  sudoers_tmp=$(mktemp)
  trap 'rm -f "$sudoers_tmp"' EXIT HUP INT TERM
  printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/aifoo-deploy-helper *\n' \
    "$DEPLOY_USER" > "$sudoers_tmp"
  chmod 0440 "$sudoers_tmp"
  visudo -cf "$sudoers_tmp" >/dev/null
  install -o root -g root -m 0440 "$sudoers_tmp" /etc/sudoers.d/aifoo-deploy-helper
fi

systemctl daemon-reload
systemctl enable --now aifoo-update-bridge.service
systemctl restart aifoo-update-bridge.service

attempts=0
while ! curl --fail --silent http://127.0.0.1:8091/health >/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 30 ]; then
    echo "Update bridge did not become healthy within 30 seconds" >&2
    systemctl status aifoo-update-bridge.service --no-pager >&2 || true
    exit 1
  fi
  sleep 1
done
printf 'control_plane_installed=true\n'
