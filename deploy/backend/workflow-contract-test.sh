#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
DEPLOY_WORKFLOW=$ROOT/.github/workflows/deploy-backend.yml
PREPARE_WORKFLOW=$ROOT/.github/workflows/backend-preparation.yml
PREFLIGHT_WORKFLOW=$ROOT/.github/workflows/preflight.yml
SYNC_WORKFLOW=$ROOT/.github/workflows/upstream-sync.yml
WEB_UPDATE_WORKFLOW=$ROOT/.github/workflows/web-update.yml
HELPER=$ROOT/deploy/backend/deploy-backend.sh
IMAGE_TEST=$ROOT/deploy/backend/image-integration-test.sh

fail() {
  echo "backend workflow contract: $1" >&2
  exit 1
}

require_text() {
  file=$1
  text=$2
  grep -F -- "$text" "$file" >/dev/null \
    || fail "missing required text in $(basename "$file"): $text"
}

reject_text() {
  file=$1
  text=$2
  if grep -F -- "$text" "$file" >/dev/null; then
    fail "forbidden text in $(basename "$file"): $text"
  fi
}

for file in \
  "$DEPLOY_WORKFLOW" "$PREPARE_WORKFLOW" "$PREFLIGHT_WORKFLOW" \
  "$SYNC_WORKFLOW" "$WEB_UPDATE_WORKFLOW" "$HELPER" "$IMAGE_TEST"; do
  [ -s "$file" ] || fail "required file is missing: $file"
done

# Preparation owns slow validation and image loading before the button appears.
require_text "$PREPARE_WORKFLOW" 'workflow_call:'
require_text "$PREPARE_WORKFLOW" 'Test the target upgrade and image-only rollback in isolation'
require_text "$PREPARE_WORKFLOW" 'deploy-sub2api-backend stage'
require_text "$PREPARE_WORKFLOW" 'deploy-sub2api-backend preflight prepared'
require_text "$PREPARE_WORKFLOW" 'backend-prepared'
require_text "$PREPARE_WORKFLOW" 'backend-prepare-failed'
require_text "$PREPARE_WORKFLOW" 'No production container, Compose file, or database was changed.'
reject_text "$PREPARE_WORKFLOW" 'deploy-sub2api-backend deploy'
reject_text "$PREPARE_WORKFLOW" 'deploy-sub2api-backend backup'
require_text "$PREPARE_WORKFLOW" '^prepare_state=(ready|already-current)$'

require_text "$SYNC_WORKFLOW" 'uses: ./.github/workflows/backend-preparation.yml'
require_text "$SYNC_WORKFLOW" 'ready_for_update:'
require_text "$SYNC_WORKFLOW" "needs.prepare.outputs.backend_deploy_required != 'true'"
require_text "$SYNC_WORKFLOW" "needs.prepare_backend.result == 'success'"
require_text "$SYNC_WORKFLOW" 'gh issue edit "$ISSUE_NUMBER" --add-label ready-for-vps'
require_text "$WEB_UPDATE_WORKFLOW" 'grep -Fxq backend-prepared'

preload_gate=$(sed -n \
  '/name: Validate the exact approved candidate/,/name: Reconfirm the preloaded activation target/p' \
  "$ROOT/.github/workflows/frontend-activation.yml")
if printf '%s\n' "$preload_gate" | grep -Fq 'grep -Fxq ready-for-vps'; then
  fail 'frontend preload depends on ready-for-vps and creates a preparation cycle'
fi
ready_line=$(grep -n 'gh issue edit "$ISSUE_NUMBER" --add-label ready-for-vps' \
  "$SYNC_WORKFLOW" | cut -d: -f1)
preload_line=$(grep -n 'preload_frontend:' "$SYNC_WORKFLOW" | cut -d: -f1)
backend_prepare_line=$(grep -n 'prepare_backend:' "$SYNC_WORKFLOW" | cut -d: -f1)
[ "$preload_line" -lt "$ready_line" ] \
  || fail 'ready-for-vps must be added after frontend preload'
[ "$backend_prepare_line" -lt "$ready_line" ] \
  || fail 'ready-for-vps must be added after backend preparation'

# The click path consumes exact preparation and does no slow image verification or isolated test.
require_text "$DEPLOY_WORKFLOW" 'workflow_dispatch:'
require_text "$DEPLOY_WORKFLOW" 'workflow_call:'
reject_text "$DEPLOY_WORKFLOW" 'schedule:'
reject_text "$DEPLOY_WORKFLOW" 'workflow_run:'
reject_text "$DEPLOY_WORKFLOW" 'pull_request:'
require_text "$DEPLOY_WORKFLOW" 'DEPLOY-AIFOO-BACKEND'
require_text "$DEPLOY_WORKFLOW" 'refs/heads/production'
require_text "$DEPLOY_WORKFLOW" 'group: aifoo-production-mutation'
require_text "$DEPLOY_WORKFLOW" 'name: production'
require_text "$DEPLOY_WORKFLOW" 'Require the exact prepared backend state'
require_text "$DEPLOY_WORKFLOW" 'deploy-sub2api-backend preflight prepared'
require_text "$DEPLOY_WORKFLOW" 'Back up PostgreSQL only when migrations will run'
require_text "$DEPLOY_WORKFLOW" 'deploy-sub2api-backend backup'
require_text "$DEPLOY_WORKFLOW" 'backup_policy=none'
require_text "$DEPLOY_WORKFLOW" 'backup_policy=postgresql'
require_text "$DEPLOY_WORKFLOW" 'backup_policy=already-current'
require_text "$DEPLOY_WORKFLOW" 'Switch only the prepared official backend service'
require_text "$DEPLOY_WORKFLOW" 'Perform one public backend health check'
require_text "$DEPLOY_WORKFLOW" 'Restore the prepared previous image after activation failure'
require_text "$DEPLOY_WORKFLOW" 'backend-production-state'
require_text "$DEPLOY_WORKFLOW" 'backend-deployed'
require_text "$DEPLOY_WORKFLOW" '--remove-label backend-deploy-required'
reject_text "$DEPLOY_WORKFLOW" 'docker pull'
reject_text "$DEPLOY_WORKFLOW" 'image-integration-test.sh'
reject_text "$DEPLOY_WORKFLOW" 'pg_dumpall'
reject_text "$DEPLOY_WORKFLOW" 'redis_command BGSAVE'
reject_text "$DEPLOY_WORKFLOW" 'backend-data.tar.gz'
reject_text "$DEPLOY_WORKFLOW" 'docker image save'
reject_text "$DEPLOY_WORKFLOW" 'restore-database'

prepared_line=$(grep -n 'name: Require the exact prepared backend state' "$DEPLOY_WORKFLOW" | cut -d: -f1)
backup_line=$(grep -n 'name: Back up PostgreSQL only when migrations will run' "$DEPLOY_WORKFLOW" | cut -d: -f1)
reconfirm_line=$(grep -n 'name: Reconfirm production revision before switching' "$DEPLOY_WORKFLOW" | cut -d: -f1)
switch_line=$(grep -n 'name: Switch only the prepared official backend service' "$DEPLOY_WORKFLOW" | cut -d: -f1)
health_line=$(grep -n 'name: Perform one public backend health check' "$DEPLOY_WORKFLOW" | cut -d: -f1)
[ "$prepared_line" -lt "$backup_line" ] || fail "prepared state must precede optional data backup"
[ "$backup_line" -lt "$reconfirm_line" ] || fail "optional data backup must precede final source check"
[ "$reconfirm_line" -lt "$switch_line" ] || fail "source must be rechecked before the switch"
[ "$switch_line" -lt "$health_line" ] || fail "switch must precede the one public health check"

# Helper contract: immutable preparation, migration-aware data backup, and image-only rollback.
sh -n "$HELPER"
require_text "$HELPER" '# BEGIN READ-ONLY PREFLIGHT'
require_text "$HELPER" '# END READ-ONLY PREFLIGHT'
require_text "$HELPER" 'prepare_backend()'
require_text "$HELPER" 'require_prepared()'
require_text "$HELPER" 'prepared_backend_status()'
require_text "$HELPER" 'create_data_backup()'
require_text "$HELPER" 'require_data_backup()'
require_text "$HELPER" 'backup_policy=none'
require_text "$HELPER" 'backup_policy=postgresql'
require_text "$HELPER" 'backup_policy=already-current'
require_text "$HELPER" 'prepare_state=already-current'
require_text "$HELPER" 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom'
require_text "$HELPER" 'pg_restore --list'
require_text "$HELPER" 'Migration updates require manual preparation while the quota flusher is enabled'
require_text "$HELPER" 'PostgreSQL backup requires the quota flusher to remain disabled'
reject_text "$HELPER" 'redis_command SCARD billing:upq:dirty'
require_text "$HELPER" 'docker_compose up -d --no-deps --force-recreate sub2api'
require_text "$HELPER" 'database_restore=not_performed'
require_text "$HELPER" 'Production drifted after preparation; refusing backend deployment'
require_text "$HELPER" 'Backend deployment state does not authorize this restore'
require_text "$HELPER" 'trap restore_interrupted_deploy EXIT HUP INT TERM'
reject_text "$HELPER" 'pg_dumpall'
reject_text "$HELPER" 'redis_command BGSAVE'
reject_text "$HELPER" 'backend-data.tar.gz'
reject_text "$HELPER" 'docker image save'
reject_text "$HELPER" 'docker image load'
reject_text "$HELPER" 'pg_restore --clean'
reject_text "$HELPER" 'restore-database'
reject_text "$HELPER" 'docker_compose down'
reject_text "$HELPER" 'docker-compose down'
reject_text "$HELPER" 'docker volume rm'
reject_text "$HELPER" 'docker system prune'

preflight_section=$(sed -n \
  '/# BEGIN READ-ONLY PREFLIGHT/,/# END READ-ONLY PREFLIGHT/p' "$HELPER")
for forbidden_preflight_command in \
  'docker pull' 'docker run' 'docker-compose up' 'docker_compose up' \
  'mkdir' 'install' 'touch' 'chmod' 'chown' 'rm -' 'mv ' 'cp '; do
  if printf '%s\n' "$preflight_section" | grep -F "$forbidden_preflight_command" >/dev/null; then
    fail "read-only preflight contains: $forbidden_preflight_command"
  fi
done

# Pure function and backup-policy checks run without Docker or production access.
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-backend-contract.XXXXXX")
cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/aifoo-backend-contract.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

cat > "$TEST_ROOT/docker-compose.yml" <<'EOF'
services:
  sub2api:
    image: weishaw/sub2api:old
    environment:
      - AUTO_SETUP=true
    volumes:
      - ./data:/app/data
  frontend:
    image: nginx:stable
  postgres:
    image: postgres:16-alpine
  redis:
    image: redis:7-alpine
EOF

AIFOO_BACKEND_DEPLOY_LIBRARY_ONLY=1
AIFOO_APP_DIR=$TEST_ROOT
AIFOO_COMPOSE_FILE=$TEST_ROOT/docker-compose.yml
AIFOO_BACKUP_ROOT=$TEST_ROOT/backups
export AIFOO_BACKEND_DEPLOY_LIBRARY_ONLY AIFOO_APP_DIR AIFOO_COMPOSE_FILE AIFOO_BACKUP_ROOT
# shellcheck source=deploy-backend.sh
# shellcheck disable=SC1091
. "$HELPER"

TEST_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TEST_RELEASE=v0.1.170
TEST_COMMIT=c043c24774228ba891ddf90d783aa6dc7d0855b5
TEST_MIGRATIONS=192_group_profit_control.sql,193_group_profit_control_auth_cache_invalidation.sql
rewrite_backend_service "$TEST_ROOT/docker-compose.yml" \
  "$TEST_ROOT/rewritten.yml" "weishaw/sub2api@$TEST_DIGEST"
require_text "$TEST_ROOT/rewritten.yml" "    image: weishaw/sub2api@$TEST_DIGEST"
require_text "$TEST_ROOT/rewritten.yml" '      - AUTO_SETUP=true'
require_text "$TEST_ROOT/rewritten.yml" '      - ./data:/app/data'
require_text "$TEST_ROOT/rewritten.yml" '    image: nginx:stable'
[ "$(grep -c '^    image: weishaw/sub2api@' "$TEST_ROOT/rewritten.yml")" -eq 1 ] \
  || fail "backend rewrite changed more than one image"

validate_digest "$TEST_DIGEST"
validate_release_tag "$TEST_RELEASE"
validate_commit "$TEST_COMMIT"
validate_migrations "$TEST_MIGRATIONS"
validate_migrations none
if (validate_migrations '../../escape.sql') >/dev/null 2>&1; then
  fail "unsafe migration input was accepted"
fi

no_backup_output=$(create_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" none)
printf '%s\n' "$no_backup_output" | grep -Fxq 'backup_id=none'
printf '%s\n' "$no_backup_output" | grep -Fxq 'backup_policy=none'
[ ! -e "$AIFOO_BACKUP_ROOT" ] || fail "migration-free backup created a directory"
require_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" none none
if require_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" none unexpected >/dev/null 2>&1; then
  fail "migration-free update accepted a data backup ID"
fi

container_field() {
  printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
}
require_prepared() {
  return 0
}
quota_flusher_state() {
  printf 'true\n'
}
if prepare_backend "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration preparation proceeded while the quota flusher was enabled"
fi
if create_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration backup proceeded while the quota flusher was enabled"
fi
[ ! -e "$AIFOO_BACKUP_ROOT" ] \
  || fail "blocked migration backup created a data directory"

quota_flusher_state() {
  return 1
}
if prepare_backend "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration preparation proceeded after quota flusher detection failed"
fi
if create_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration backup proceeded after quota flusher detection failed"
fi
[ ! -e "$AIFOO_BACKUP_ROOT" ] \
  || fail "failed quota detection created a data directory"

quota_flusher_state() {
  :
}
if prepare_backend "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration preparation accepted an empty quota flusher state"
fi
if create_data_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" >/dev/null 2>&1; then
  fail "migration backup accepted an empty quota flusher state"
fi
[ ! -e "$AIFOO_BACKUP_ROOT" ] \
  || fail "empty quota state created a data directory"

require_text "$IMAGE_TEST" 'backend_image_integration=ok'
require_text "$IMAGE_TEST" 'image_only_rollback_compatibility=verified'

echo "backend_workflow_contract=ok"
