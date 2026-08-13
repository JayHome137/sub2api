#!/bin/sh

set -eu

BACKEND_HELPER=/usr/local/sbin/deploy-sub2api-backend
BRIDGE_BINARY=/usr/local/libexec/aifoo-update-bridge
BRIDGE_SERVICE=aifoo-update-bridge
BACKUP_ROOT=/var/backups/aifoo-control-plane
STATE_DIR=/var/lib/aifoo-control-plane
STATE_FILE=$STATE_DIR/last-update.env
RUN_ROOT=/run/aifoo-control-plane
BRIDGE_HEALTH_URL=http://127.0.0.1:8091/health
SIGNING_PUBLIC_KEY=/etc/aifoo-control-plane/component-signing-public.pem
SELF=$0

fail() {
  echo "control-plane update: $1" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" = 0 ] || fail 'this command must run as root'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

validate_sha() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$' \
    || fail 'expected a lowercase SHA-256 checksum'
}

secure_regular_file() {
  file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(stat -c '%U' "$file" 2>/dev/null || true)" = root ] || return 1
  ! find "$file" -perm /022 -print -quit 2>/dev/null | grep -q .
}

secure_directory() {
  directory=$1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  [ "$(stat -c '%U' "$directory" 2>/dev/null || true)" = root ] || return 1
  ! find "$directory" -maxdepth 0 -perm /022 -print -quit 2>/dev/null | grep -q .
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

verify_bridge_health() {
  systemctl is-active --quiet "$BRIDGE_SERVICE" \
    || { echo 'bridge_service=inactive' >&2; return 1; }
  curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$BRIDGE_HEALTH_URL" | grep -Fq '"status":"ok"' \
    || { echo 'bridge_health=failed' >&2; return 1; }
}

verify_installed() {
  expected_helper_sha=$1
  expected_bridge_sha=$2
  expected_control_plane_sha=$3
  validate_sha "$expected_helper_sha"
  validate_sha "$expected_bridge_sha"
  validate_sha "$expected_control_plane_sha"

  secure_regular_file "$SELF" || fail 'control-plane helper is not root-owned and protected'
  secure_regular_file "$BACKEND_HELPER" || fail 'backend helper is not root-owned and protected'
  secure_regular_file "$BRIDGE_BINARY" || fail 'update bridge is not root-owned and protected'
  secure_directory /usr/local/sbin || fail 'backend helper directory is not root-owned and protected'
  secure_directory /usr/local/libexec || fail 'update bridge directory is not root-owned and protected'
  secure_directory /etc/aifoo-control-plane \
    || fail 'control-plane signing key directory is not root-owned and protected'
  secure_regular_file "$SIGNING_PUBLIC_KEY" \
    || fail 'control-plane signing public key is not root-owned and protected'
  [ "$(sha256_file "$SELF")" = "$expected_control_plane_sha" ] \
    || fail 'control-plane helper SHA-256 does not match the requested revision'
  [ "$(sha256_file "$BACKEND_HELPER")" = "$expected_helper_sha" ] \
    || fail 'backend helper SHA-256 does not match the requested revision'
  [ "$(sha256_file "$BRIDGE_BINARY")" = "$expected_bridge_sha" ] \
    || fail 'update bridge SHA-256 does not match the requested revision'
  verify_bridge_health
}

preflight() {
  expected_helper_sha=${1:-}
  expected_bridge_sha=${2:-}
  expected_control_plane_sha=${3:-}
  validate_sha "$expected_helper_sha"
  validate_sha "$expected_bridge_sha"
  validate_sha "$expected_control_plane_sha"
  for command_name in sha256sum tar mktemp install mv cp systemctl curl stat find flock openssl; do
    require_command "$command_name"
  done
  secure_regular_file "$SELF" || fail 'control-plane helper is not root-owned and protected'
  secure_directory /usr/local/sbin || fail 'backend helper directory is not root-owned and protected'
  secure_directory /usr/local/libexec || fail 'update bridge directory is not root-owned and protected'
  secure_directory /etc/aifoo-control-plane \
    || fail 'control-plane signing key directory is not root-owned and protected'
  secure_regular_file "$SIGNING_PUBLIC_KEY" \
    || fail 'control-plane signing public key is not root-owned and protected'
  secure_regular_file "$BACKEND_HELPER" || fail 'backend helper is not root-owned and protected'
  secure_regular_file "$BRIDGE_BINARY" || fail 'update bridge is not root-owned and protected'
  [ "$(sha256_file "$SELF")" = "$expected_control_plane_sha" ] \
    || fail 'control-plane helper SHA-256 does not match the requested revision; rerun the root bootstrap from this revision'
  current_helper_sha=$(sha256_file "$BACKEND_HELPER")
  current_bridge_sha=$(sha256_file "$BRIDGE_BINARY")
  current_control_plane_sha=$(sha256_file "$SELF")
  verify_bridge_health
  printf 'control_plane_preflight=ready\n'
  printf 'current_backend_helper_sha256=%s\n' "$current_helper_sha"
  printf 'current_update_bridge_sha256=%s\n' "$current_bridge_sha"
  printf 'target_backend_helper_sha256=%s\n' "$expected_helper_sha"
  printf 'target_update_bridge_sha256=%s\n' "$expected_bridge_sha"
  printf 'current_control_plane_helper_sha256=%s\n' "$current_control_plane_sha"
  printf 'target_control_plane_helper_sha256=%s\n' "$expected_control_plane_sha"
  printf 'sub2api_service_untouched=true\n'
}

validate_archive_path() {
  archive=$1
  printf '%s\n' "$archive" \
    | grep -Eq '^/tmp/aifoo-control-plane-[0-9]+-[0-9]+\.tar\.gz$' \
    || fail 'archive must be the exact workflow temporary path under /tmp'
  [ -f "$archive" ] && [ ! -L "$archive" ] \
    || fail 'component archive is missing or unsafe'
}

require_no_symlink_members() {
  archive=$1
  tar -tvzf "$archive" | awk '
    substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { found=1 }
    END { exit found ? 0 : 1 }
  ' && fail 'component archive must not contain links'
}

verify_archive_members() {
  archive=$1
  entries=$(tar -tzf "$archive") || fail 'component archive cannot be listed'
  entry_count=$(printf '%s\n' "$entries" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$entry_count" = 4 ] || fail 'component archive must contain exactly four files'
  printf '%s\n' "$entries" | grep -Fxq deploy-backend.sh \
    || fail 'component archive is missing backend helper payload'
  printf '%s\n' "$entries" | grep -Fxq aifoo-update-bridge \
    || fail 'component archive is missing bridge payload'
  printf '%s\n' "$entries" | grep -Fxq manifest.env \
    || fail 'component archive is missing signed manifest'
  printf '%s\n' "$entries" | grep -Fxq manifest.sig \
    || fail 'component archive is missing manifest signature'
}

manifest_value() {
  key=$1
  manifest=$2
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest"
}

verify_signed_manifest() {
  stage_dir=$1
  expected_helper_sha=$2
  expected_bridge_sha=$3
  manifest=$stage_dir/manifest.env
  signature=$stage_dir/manifest.sig
  secure_regular_file "$SIGNING_PUBLIC_KEY" \
    || fail 'control-plane signing public key is not root-owned and protected'
  [ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || fail 'component manifest is unsafe'
  [ -f "$signature" ] && [ ! -L "$signature" ] \
    || fail 'component manifest signature is unsafe'
  [ ! -s "$signature" ] && fail 'component manifest signature is empty'
  [ "$(wc -l < "$manifest" | tr -d ' ')" = 3 ] \
    || fail 'component manifest has an invalid line count'
  sed -n '1p' "$manifest" | grep -Fxq 'schema=1' \
    || fail 'component manifest schema is invalid'
  sed -n '2p' "$manifest" | grep -Eq '^backend_helper_sha256=[0-9a-f]{64}$' \
    || fail 'component manifest backend helper checksum is invalid'
  sed -n '3p' "$manifest" | grep -Eq '^update_bridge_sha256=[0-9a-f]{64}$' \
    || fail 'component manifest bridge checksum is invalid'
  openssl dgst -sha256 -verify "$SIGNING_PUBLIC_KEY" \
    -signature "$signature" "$manifest" >/dev/null \
    || fail 'component manifest signature verification failed'
  [ "$(manifest_value backend_helper_sha256 "$manifest")" = "$expected_helper_sha" ] \
    || fail 'signed manifest backend helper checksum does not match'
  [ "$(manifest_value update_bridge_sha256 "$manifest")" = "$expected_bridge_sha" ] \
    || fail 'signed manifest bridge checksum does not match'
}

make_backup() {
  umask 077
  install -d -o root -g root -m 0700 "$BACKUP_ROOT" "$STATE_DIR" "$RUN_ROOT"
  backup_id="$(date -u +%Y%m%d-%H%M%S)-control-plane"
  backup_dir=$BACKUP_ROOT/$backup_id
  mkdir "$backup_dir" || fail 'could not create control-plane backup directory'
  chmod 0700 "$backup_dir"
  cp -p "$BACKEND_HELPER" "$backup_dir/deploy-sub2api-backend" \
    || fail 'could not back up backend helper'
  cp -p "$BRIDGE_BINARY" "$backup_dir/aifoo-update-bridge" \
    || fail 'could not back up update bridge'
  helper_sha=$(sha256_file "$backup_dir/deploy-sub2api-backend")
  bridge_sha=$(sha256_file "$backup_dir/aifoo-update-bridge")
  state_tmp=$(mktemp "$STATE_DIR/.last-update.XXXXXX")
  {
    printf 'backup_dir=%s\n' "$backup_dir"
    printf 'backend_helper_sha256=%s\n' "$helper_sha"
    printf 'update_bridge_sha256=%s\n' "$bridge_sha"
  } > "$state_tmp"
  chown root:root "$state_tmp"
  chmod 0600 "$state_tmp"
  mv -f "$state_tmp" "$STATE_FILE"
  printf '%s\n' "$backup_dir"
}

state_value() {
  key=$1
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE"
}

validate_backup_dir() {
  backup_dir=$1
  case "$backup_dir" in
    "$BACKUP_ROOT"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-control-plane) ;;
    *) fail 'backup state contains an unsafe directory' ;;
  esac
  [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] \
    || fail 'control-plane backup directory is unavailable'
}

restore_backup() {
  expected_control_plane_sha=$1
  validate_sha "$expected_control_plane_sha"
  secure_regular_file "$SELF" || fail 'control-plane helper is not root-owned and protected'
  [ "$(sha256_file "$SELF")" = "$expected_control_plane_sha" ] \
    || fail 'control-plane helper SHA-256 does not match the requested revision'
  secure_regular_file "$STATE_FILE" || fail 'control-plane backup state is unavailable'
  backup_dir=$(state_value backup_dir)
  expected_helper_sha=$(state_value backend_helper_sha256)
  expected_bridge_sha=$(state_value update_bridge_sha256)
  validate_backup_dir "$backup_dir"
  validate_sha "$expected_helper_sha"
  validate_sha "$expected_bridge_sha"
  old_helper=$backup_dir/deploy-sub2api-backend
  old_bridge=$backup_dir/aifoo-update-bridge
  [ -f "$old_helper" ] && [ ! -L "$old_helper" ] \
    || fail 'backup backend helper is unavailable'
  [ -f "$old_bridge" ] && [ ! -L "$old_bridge" ] \
    || fail 'backup update bridge is unavailable'
  [ "$(sha256_file "$old_helper")" = "$expected_helper_sha" ] \
    || fail 'backup backend helper checksum failed'
  [ "$(sha256_file "$old_bridge")" = "$expected_bridge_sha" ] \
    || fail 'backup update bridge checksum failed'

  helper_tmp=$(mktemp /usr/local/sbin/.deploy-sub2api-backend.restore.XXXXXX)
  bridge_tmp=$(mktemp /usr/local/libexec/.aifoo-update-bridge.restore.XXXXXX)
  install -o root -g root -m 0755 "$old_helper" "$helper_tmp"
  install -o root -g root -m 0755 "$old_bridge" "$bridge_tmp"
  [ "$(sha256_file "$helper_tmp")" = "$expected_helper_sha" ] \
    && [ "$(sha256_file "$bridge_tmp")" = "$expected_bridge_sha" ] \
    || fail 'staged rollback checksums failed'
  mv -f "$helper_tmp" "$BACKEND_HELPER"
  mv -f "$bridge_tmp" "$BRIDGE_BINARY"
  systemctl restart "$BRIDGE_SERVICE"
  verify_bridge_health || fail 'bridge did not recover after control-plane rollback'
  printf 'control_plane_rollback=ready\n'
  printf 'sub2api_service_untouched=true\n'
}

install_components() {
  archive=${1:-}
  expected_archive_sha=${2:-}
  expected_helper_sha=${3:-}
  expected_bridge_sha=${4:-}
  expected_control_plane_sha=${5:-}
  validate_archive_path "$archive"
  validate_sha "$expected_archive_sha"
  preflight "$expected_helper_sha" "$expected_bridge_sha" "$expected_control_plane_sha"

  install -d -o root -g root -m 0700 "$RUN_ROOT"
  archive_copy=
  stage_dir=
  helper_tmp=
  bridge_tmp=
  install_started=false
  cleanup_stage() {
    [ -n "$archive_copy" ] && rm -f -- "$archive_copy"
    [ -n "$helper_tmp" ] && rm -f -- "$helper_tmp"
    [ -n "$bridge_tmp" ] && rm -f -- "$bridge_tmp"
    if [ -n "$stage_dir" ]; then
      rm -f -- "$stage_dir/deploy-backend.sh" "$stage_dir/aifoo-update-bridge" \
        "$stage_dir/manifest.env" "$stage_dir/manifest.sig"
      rmdir "$stage_dir" 2>/dev/null || true
    fi
  }
  recover_interrupted_install() {
    status=$1
    trap - EXIT HUP INT TERM
    if [ "$install_started" = true ]; then
      echo 'control-plane update interrupted; restoring immediate local backup' >&2
      restore_backup "$expected_control_plane_sha" || true
    fi
    cleanup_stage
    exit "$status"
  }
  trap 'recover_interrupted_install "$?"' EXIT
  trap 'recover_interrupted_install 129' HUP
  trap 'recover_interrupted_install 130' INT
  trap 'recover_interrupted_install 143' TERM
  archive_copy=$(mktemp "$RUN_ROOT/archive.XXXXXX")
  stage_dir=$(mktemp -d "$RUN_ROOT/payload.XXXXXX")
  install -o root -g root -m 0600 "$archive" "$archive_copy"
  [ "$(sha256_file "$archive_copy")" = "$expected_archive_sha" ] \
    || fail 'component archive SHA-256 does not match the verified upload'
  verify_archive_members "$archive_copy"
  require_no_symlink_members "$archive_copy"
  tar -xzf "$archive_copy" -C "$stage_dir" --no-same-owner --no-same-permissions
  [ -f "$stage_dir/deploy-backend.sh" ] && [ ! -L "$stage_dir/deploy-backend.sh" ] \
    || fail 'backend helper payload is unsafe'
  [ -f "$stage_dir/aifoo-update-bridge" ] && [ ! -L "$stage_dir/aifoo-update-bridge" ] \
    || fail 'update bridge payload is unsafe'
  verify_signed_manifest "$stage_dir" "$expected_helper_sha" "$expected_bridge_sha"
  [ "$(sha256_file "$stage_dir/deploy-backend.sh")" = "$expected_helper_sha" ] \
    || fail 'backend helper payload SHA-256 does not match'
  [ "$(sha256_file "$stage_dir/aifoo-update-bridge")" = "$expected_bridge_sha" ] \
    || fail 'update bridge payload SHA-256 does not match'

  backup_dir=$(make_backup)
  helper_tmp=$(mktemp /usr/local/sbin/.deploy-sub2api-backend.update.XXXXXX)
  bridge_tmp=$(mktemp /usr/local/libexec/.aifoo-update-bridge.update.XXXXXX)
  install -o root -g root -m 0755 "$stage_dir/deploy-backend.sh" "$helper_tmp"
  install -o root -g root -m 0755 "$stage_dir/aifoo-update-bridge" "$bridge_tmp"
  if [ "$(sha256_file "$helper_tmp")" != "$expected_helper_sha" ] \
    || [ "$(sha256_file "$bridge_tmp")" != "$expected_bridge_sha" ]; then
    rm -f -- "$helper_tmp" "$bridge_tmp"
    fail 'staged component checksums failed'
  fi
  install_started=true
  mv -f "$helper_tmp" "$BACKEND_HELPER"
  helper_tmp=
  mv -f "$bridge_tmp" "$BRIDGE_BINARY"
  bridge_tmp=
  if ! systemctl restart "$BRIDGE_SERVICE" || ! verify_bridge_health; then
    echo 'control-plane update failed; restoring immediate local backup' >&2
    restore_backup "$expected_control_plane_sha" || true
    fail 'bridge verification failed after component update'
  fi
  install_started=false
  rm -f -- "$archive"
  trap - EXIT HUP INT TERM
  cleanup_stage
  printf 'control_plane_install=ready\n'
  printf 'control_plane_backup=%s\n' "$backup_dir"
  printf 'sub2api_service_untouched=true\n'
}

main() {
  require_root
  command=${1:-}
  shift || true
  case "$command" in
    preflight)
      [ "$#" -eq 3 ] || fail 'preflight requires helper, bridge, and control-plane SHA-256 values'
      preflight "$@"
      ;;
    install)
      [ "$#" -eq 5 ] || fail 'install requires archive and four SHA-256 values'
      install -d -o root -g root -m 0755 /usr/local/sbin /usr/local/libexec
      exec 9>/run/lock/aifoo-control-plane.lock
      flock -n 9 || fail 'another control-plane update is already running'
      install_components "$@"
      ;;
    verify)
      [ "$#" -eq 3 ] || fail 'verify requires helper, bridge, and control-plane SHA-256 values'
      verify_installed "$@"
      printf 'control_plane_verify=ready\n'
      printf 'sub2api_service_untouched=true\n'
      ;;
    rollback)
      [ "$#" -eq 1 ] || fail 'rollback requires the control-plane SHA-256 value'
      exec 9>/run/lock/aifoo-control-plane.lock
      flock -n 9 || fail 'another control-plane update is already running'
      restore_backup "${1:-}"
      ;;
    *)
      fail 'usage: deploy-update-components {preflight <helper-sha> <bridge-sha> <control-plane-sha>|install <archive> <archive-sha> <helper-sha> <bridge-sha> <control-plane-sha>|verify <helper-sha> <bridge-sha> <control-plane-sha>|rollback <control-plane-sha>}'
      ;;
  esac
}

if [ "${AIFOO_CONTROL_PLANE_LIBRARY_ONLY:-0}" != 1 ]; then
  main "$@"
fi
