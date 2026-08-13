#!/bin/sh

set -eu

INSTALL_PATH=/usr/local/sbin/deploy-update-components
SUDOERS_PATH=/etc/sudoers.d/aifoo-update-components
SIGNING_PUBLIC_KEY_PATH=/etc/aifoo-control-plane/component-signing-public.pem
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SOURCE_HELPER=$SCRIPT_DIR/deploy-update-components.sh

fail() {
  echo "control-plane bootstrap: $1" >&2
  exit 1
}

[ -x /usr/sbin/visudo ] || fail 'visudo is required for the narrow sudo policy'
command -v openssl >/dev/null 2>&1 || fail 'openssl is required to validate the signing public key'
[ "$(id -u)" = 0 ] || fail 'this bootstrap must run as root'
[ "${1:-}" = --sudo-user ] || fail 'usage: install-control-plane.sh --sudo-user <restricted-ssh-user> --signing-public-key <path>'
sudo_user=${2:-}
[ "${3:-}" = --signing-public-key ] || fail 'usage: install-control-plane.sh --sudo-user <restricted-ssh-user> --signing-public-key <path>'
signing_public_key=${4:-}
printf '%s\n' "$sudo_user" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$' \
  || fail 'sudo user name is invalid'
id -u "$sudo_user" >/dev/null 2>&1 || fail 'sudo user does not exist'
[ "$(id -u "$sudo_user")" != 0 ] \
  || fail 'sudo user must be the restricted non-root SSH user'
[ -f "$SOURCE_HELPER" ] && [ ! -L "$SOURCE_HELPER" ] \
  || fail 'control-plane helper source is unavailable'
if find "$SOURCE_HELPER" -perm /022 -print -quit 2>/dev/null | grep -q .; then
  fail 'control-plane helper source must not be group or world writable'
fi
[ -f "$signing_public_key" ] && [ ! -L "$signing_public_key" ] \
  || fail 'signing public key is unavailable'
openssl pkey -pubin -in "$signing_public_key" -noout >/dev/null 2>&1 \
  || fail 'signing public key is invalid'

install -d -o root -g root -m 0755 /usr/local/sbin
helper_tmp=$(mktemp /usr/local/sbin/.deploy-update-components.XXXXXX)
install -o root -g root -m 0755 "$SOURCE_HELPER" "$helper_tmp"
mv -f "$helper_tmp" "$INSTALL_PATH"

install -d -o root -g root -m 0700 /etc/aifoo-control-plane
key_tmp=$(mktemp /etc/aifoo-control-plane/.component-signing-public.XXXXXX)
install -o root -g root -m 0644 "$signing_public_key" "$key_tmp"
mv -f "$key_tmp" "$SIGNING_PUBLIC_KEY_PATH"

sudoers_tmp=$(mktemp /etc/sudoers.d/.aifoo-update-components.XXXXXX)
{
  printf 'Cmnd_Alias AIFOO_CONTROL_PLANE = %s preflight [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]*, ' "$INSTALL_PATH"
  printf '%s install /tmp/aifoo-control-plane-[0-9][0-9]*-[0-9][0-9]*.tar.gz [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]*, ' "$INSTALL_PATH"
  printf '%s verify [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]* [0-9a-f][0-9a-f]*, ' "$INSTALL_PATH"
  printf '%s rollback [0-9a-f][0-9a-f]*\n' "$INSTALL_PATH"
  printf '%s ALL=(root) NOPASSWD: AIFOO_CONTROL_PLANE\n' "$sudo_user"
} > "$sudoers_tmp"
chown root:root "$sudoers_tmp"
chmod 0440 "$sudoers_tmp"
visudo -cf "$sudoers_tmp" >/dev/null || {
  rm -f -- "$sudoers_tmp"
  fail 'generated sudoers policy is invalid'
}
mv -f "$sudoers_tmp" "$SUDOERS_PATH"
visudo -cf "$SUDOERS_PATH" >/dev/null

printf 'control_plane_bootstrap=ready\n'
printf 'control_plane_helper_sha256=%s\n' "$(sha256sum "$INSTALL_PATH" | awk '{print $1}')"
printf 'control_plane_signing_public_key_sha256=%s\n' "$(sha256sum "$SIGNING_PUBLIC_KEY_PATH" | awk '{print $1}')"
