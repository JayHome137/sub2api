#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORKFLOW=$ROOT/.github/workflows/deploy-update-components.yml
HELPER=$ROOT/deploy/control-plane/deploy-update-components.sh
BOOTSTRAP=$ROOT/deploy/control-plane/install-control-plane.sh
INTEGRATION_TEST=$ROOT/deploy/control-plane/integration-test.sh
PUBLIC_KEY=$ROOT/deploy/control-plane/component-signing-public.pem

fail() {
  echo "control-plane workflow contract: $1" >&2
  exit 1
}

require_text() {
  file=$1
  text=$2
  grep -Fq -- "$text" "$file" || fail "missing required text in $(basename "$file"): $text"
}

reject_text() {
  file=$1
  text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "forbidden text in $(basename "$file"): $text"
  fi
}

for file in "$WORKFLOW" "$HELPER" "$BOOTSTRAP" "$INTEGRATION_TEST" "$PUBLIC_KEY"; do
  [ -s "$file" ] || fail "required file is missing: $file"
done

sh -n "$HELPER"
sh -n "$BOOTSTRAP"
sh -n "$INTEGRATION_TEST"
openssl pkey -pubin -in "$PUBLIC_KEY" -noout >/dev/null
require_text "$WORKFLOW" 'workflow_dispatch:'
require_text "$WORKFLOW" 'UPDATE-AIFOO-CONTROL-PLANE'
require_text "$WORKFLOW" 'deploy-update-components preflight'
require_text "$WORKFLOW" 'deploy-update-components install'
require_text "$WORKFLOW" 'deploy-update-components verify'
require_text "$WORKFLOW" 'deploy-update-components rollback'
require_text "$WORKFLOW" 'go test ./...'
require_text "$WORKFLOW" 'go vet ./...'
require_text "$WORKFLOW" 'ARCHIVE_SHA'
require_text "$WORKFLOW" 'id: upload'
require_text "$WORKFLOW" 'AIFOO_CONTROL_PLANE_SIGNING_KEY'
require_text "$WORKFLOW" 'openssl dgst -sha256 -sign'
require_text "$WORKFLOW" 'does not match the committed public key'
require_text "$WORKFLOW" "printf 'schema=1\\n'"
require_text "$WORKFLOW" 'deploy-backend.sh aifoo-update-bridge manifest.env manifest.sig'
reject_text "$WORKFLOW" 'archive_sha256='
reject_text "$WORKFLOW" 'web-update.yml'
reject_text "$WORKFLOW" 'docker-compose'
reject_text "$WORKFLOW" 'systemctl restart sub2api'
reject_text "$WORKFLOW" 'systemctl restart nginx'
reject_text "$WORKFLOW" 'nginx -'

require_text "$HELPER" 'BACKEND_HELPER=/usr/local/sbin/deploy-sub2api-backend'
require_text "$HELPER" 'BRIDGE_SERVICE=aifoo-update-bridge'
require_text "$HELPER" 'verify_bridge_health'
require_text "$HELPER" 'secure_directory()'
require_text "$HELPER" 'SIGNING_PUBLIC_KEY=/etc/aifoo-control-plane/component-signing-public.pem'
require_text "$HELPER" 'verify_signed_manifest()'
require_text "$HELPER" 'openssl dgst -sha256 -verify'
require_text "$HELPER" 'require_no_symlink_members()'
require_text "$HELPER" "grep -Fxq 'schema=1'"
require_text "$HELPER" 'recover_interrupted_install()'
require_text "$HELPER" 'make_backup()'
require_text "$HELPER" 'restore_backup()'
require_text "$HELPER" 'control_plane_install=ready'
require_text "$HELPER" 'sub2api_service_untouched=true'
require_text "$HELPER" 'tar -xzf'
require_text "$HELPER" 'systemctl restart "$BRIDGE_SERVICE"'
reject_text "$HELPER" 'docker-compose'
reject_text "$HELPER" 'docker compose'
reject_text "$HELPER" 'pg_dump'
reject_text "$HELPER" 'psql '
reject_text "$HELPER" 'nginx '
reject_text "$HELPER" 'sub2api.service'
reject_text "$HELPER" 'archive_sha256='

require_text "$BOOTSTRAP" 'Cmnd_Alias AIFOO_CONTROL_PLANE'
require_text "$BOOTSTRAP" 'NOPASSWD: AIFOO_CONTROL_PLANE'
require_text "$BOOTSTRAP" 'visudo -cf'
require_text "$BOOTSTRAP" 'install -o root -g root -m 0755'
require_text "$BOOTSTRAP" "id -u \"\$sudo_user\""
require_text "$BOOTSTRAP" 'source must not be group or world writable'
require_text "$BOOTSTRAP" '--signing-public-key'
require_text "$BOOTSTRAP" 'SIGNING_PUBLIC_KEY_PATH=/etc/aifoo-control-plane/component-signing-public.pem'
reject_text "$BOOTSTRAP" 'ALL=(ALL) NOPASSWD: ALL'

preflight_body=$(sed -n '/^preflight()/,/^}/p' "$HELPER")
printf '%s\n' "$preflight_body" | grep -Fq 'current_backend_helper_sha256=' \
  || fail 'preflight must report the currently installed backend helper'
printf '%s\n' "$preflight_body" | grep -Fq 'target_backend_helper_sha256=' \
  || fail 'preflight must report the target backend helper'
printf '%s\n' "$preflight_body" | grep -Fq 'current_control_plane_helper_sha256=' \
  || fail 'preflight must report the currently installed control-plane helper'
printf '%s\n' "$preflight_body" | grep -Fq 'target_control_plane_helper_sha256=' \
  || fail 'preflight must report the target control-plane helper'
printf '%s\n' "$preflight_body" | grep -Fq 'rerun the root bootstrap from this revision' \
  || fail 'preflight must require the exact root-bootstrap revision'
if printf '%s\n' "$preflight_body" | grep -Fq 'verify_installed'; then
  fail 'preflight must not require target component hashes before installation'
fi

"$INTEGRATION_TEST"

echo 'control_plane_workflow_contract=ok'
