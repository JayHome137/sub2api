#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
DEPLOY_WORKFLOW=$ROOT/.github/workflows/deploy-backend.yml
PREFLIGHT_WORKFLOW=$ROOT/.github/workflows/preflight.yml
SYNC_WORKFLOW=$ROOT/.github/workflows/upstream-sync.yml
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

for file in "$DEPLOY_WORKFLOW" "$PREFLIGHT_WORKFLOW" "$SYNC_WORKFLOW" "$HELPER" "$IMAGE_TEST"; do
  [ -s "$file" ] || fail "required file is missing: $file"
done

require_text "$DEPLOY_WORKFLOW" 'workflow_dispatch:'
require_text "$DEPLOY_WORKFLOW" 'workflow_call:'
reject_text "$DEPLOY_WORKFLOW" 'schedule:'
reject_text "$DEPLOY_WORKFLOW" 'workflow_run:'
reject_text "$DEPLOY_WORKFLOW" 'pull_request:'
require_text "$DEPLOY_WORKFLOW" 'DEPLOY-AIFOO-BACKEND'
require_text "$DEPLOY_WORKFLOW" 'Only the repository owner can approve a backend deployment'
require_text "$DEPLOY_WORKFLOW" 'refs/heads/production'
require_text "$DEPLOY_WORKFLOW" 'group: aifoo-production-mutation'
require_text "$DEPLOY_WORKFLOW" 'name: production'
require_text "$DEPLOY_WORKFLOW" "weishaw/sub2api@\$IMAGE_DIGEST"
require_text "$DEPLOY_WORKFLOW" "git merge-base --is-ancestor \"\$release_commit\" \"\$GITHUB_SHA\""
require_text "$DEPLOY_WORKFLOW" 'labels=upstream-release'
require_text "$DEPLOY_WORKFLOW" 'grep -Fxq ready-for-vps'
require_text "$DEPLOY_WORKFLOW" 'Calculate migrations from the running production release'
require_text "$DEPLOY_WORKFLOW" 'Test target upgrade and image-only rollback with isolated services'
require_text "$DEPLOY_WORKFLOW" 'Require a fresh read-only backend preflight'
require_text "$DEPLOY_WORKFLOW" 'target_state=current'
require_text "$DEPLOY_WORKFLOW" 'Back up backend data, PostgreSQL, Redis, Compose, and the current image'
require_text "$DEPLOY_WORKFLOW" 'Reconfirm production revision before backend deployment'
require_text "$DEPLOY_WORKFLOW" 'Deploy only the official backend service'
require_text "$DEPLOY_WORKFLOW" 'Close the automatic backend restore gate'
require_text "$DEPLOY_WORKFLOW" 'Restore the previous backend image after backend failure'
require_text "$DEPLOY_WORKFLOW" 'Verify unchanged public frontend'
require_text "$DEPLOY_WORKFLOW" "steps.backend-restore-gate.outputs.passed != 'true'"
require_text "$DEPLOY_WORKFLOW" 'restore-image'
require_text "$DEPLOY_WORKFLOW" 'backend-production-state'
require_text "$DEPLOY_WORKFLOW" 'backend-deployed'
require_text "$DEPLOY_WORKFLOW" '--remove-label backend-deploy-required'
require_text "$DEPLOY_WORKFLOW" 'manual disaster-recovery approval only'
reject_text "$DEPLOY_WORKFLOW" 'restore-database'
reject_text "$DEPLOY_WORKFLOW" 'pg_restore'
reject_text "$DEPLOY_WORKFLOW" 'actions/upload-artifact'

require_text "$PREFLIGHT_WORKFLOW" 'workflow_dispatch:'
reject_text "$PREFLIGHT_WORKFLOW" 'schedule:'
require_text "$PREFLIGHT_WORKFLOW" 'group: aifoo-production-mutation'
require_text "$PREFLIGHT_WORKFLOW" 'Run read-only backend preflight'
require_text "$PREFLIGHT_WORKFLOW" 'deploy-sub2api-backend preflight'
require_text "$PREFLIGHT_WORKFLOW" 'Deployment files changed:'
require_text "$PREFLIGHT_WORKFLOW" 'Containers changed:'
reject_text "$PREFLIGHT_WORKFLOW" 'deploy-sub2api-backend stage'
reject_text "$PREFLIGHT_WORKFLOW" 'deploy-sub2api-backend backup'
reject_text "$PREFLIGHT_WORKFLOW" 'deploy-sub2api-backend deploy'

backup_line=$(grep -n 'name: Back up backend data' "$DEPLOY_WORKFLOW" | cut -d: -f1)
reconfirm_line=$(grep -n 'name: Reconfirm production revision' "$DEPLOY_WORKFLOW" | cut -d: -f1)
deploy_line=$(grep -n 'name: Deploy only the official backend service' "$DEPLOY_WORKFLOW" | cut -d: -f1)
migration_line=$(grep -n 'name: Calculate migrations from the running production release' "$DEPLOY_WORKFLOW" | cut -d: -f1)
image_test_line=$(grep -n 'name: Test target upgrade and image-only rollback' "$DEPLOY_WORKFLOW" | cut -d: -f1)
smoke_line=$(grep -n 'name: Public backend smoke check' "$DEPLOY_WORKFLOW" | cut -d: -f1)
gate_line=$(grep -n 'name: Close the automatic backend restore gate' "$DEPLOY_WORKFLOW" | cut -d: -f1)
restore_line=$(grep -n 'name: Restore the previous backend image after backend failure' "$DEPLOY_WORKFLOW" | cut -d: -f1)
frontend_line=$(grep -n 'name: Verify unchanged public frontend' "$DEPLOY_WORKFLOW" | cut -d: -f1)
[ "$migration_line" -lt "$image_test_line" ] || fail "production migration plan must precede image testing"
[ "$image_test_line" -lt "$backup_line" ] || fail "rollback compatibility must be proven before backup"
[ "$backup_line" -lt "$reconfirm_line" ] || fail "backup must precede final source confirmation"
[ "$reconfirm_line" -lt "$deploy_line" ] || fail "final source confirmation must precede deployment"
[ "$deploy_line" -lt "$smoke_line" ] || fail "deployment must precede public backend smoke"
[ "$smoke_line" -lt "$gate_line" ] || fail "backend checks must precede the restore gate"
[ "$gate_line" -lt "$restore_line" ] || fail "restore step must immediately follow the backend gate"
[ "$restore_line" -lt "$frontend_line" ] || fail "unchanged frontend checks must not drive backend restore"

require_text "$HELPER" '# BEGIN READ-ONLY PREFLIGHT'
require_text "$HELPER" '# END READ-ONLY PREFLIGHT'
require_text "$HELPER" 'preflight_result=ready'
require_text "$HELPER" 'target_state=current'
require_text "$HELPER" 'backend_local_health_failed'
require_text "$HELPER" 'redis_ping_failed'
require_text "$HELPER" 'docker run --rm --network none --entrypoint /app/sub2api'
require_text "$HELPER" "pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" --format=custom"
require_text "$HELPER" "pg_dumpall -U \"\$POSTGRES_USER\" --globals-only --no-role-passwords"
require_text "$HELPER" 'redis_command BGSAVE'
require_text "$HELPER" 'docker image save --output'
require_text "$HELPER" 'backend-data.tar.gz'
require_text "$HELPER" 'sha256sum -c SHA256SUMS'
require_text "$HELPER" 'flock -n 9'
require_text "$HELPER" 'Production drifted after backup; refusing backend deployment'
require_text "$HELPER" 'Backend deployment state does not authorize this restore'
require_text "$HELPER" 'require_backup_metadata'
require_text "$HELPER" 'candidate_compose_sha256'
require_text "$HELPER" 'rollback_compose_sha256'
require_text "$HELPER" 'target_image_id'
require_text "$HELPER" "trap 'cleanup_incomplete_backup 143' TERM"
require_text "$HELPER" 'Backend backup is missing a required non-empty file'
require_text "$HELPER" 'trap restore_interrupted_deploy EXIT HUP INT TERM'
require_text "$HELPER" 'docker_compose up -d --no-deps --force-recreate sub2api'
require_text "$HELPER" 'database_restore=not_performed'
reject_text "$HELPER" 'docker_compose down'
reject_text "$HELPER" 'docker-compose down'
reject_text "$HELPER" 'docker volume rm'
reject_text "$HELPER" 'docker system prune'
require_text "$HELPER" 'pg_restore --list'
reject_text "$HELPER" 'pg_restore --clean'
reject_text "$HELPER" 'restore-database'

preflight_section=$(sed -n \
  '/# BEGIN READ-ONLY PREFLIGHT/,/# END READ-ONLY PREFLIGHT/p' "$HELPER")
for forbidden_preflight_command in \
  'docker pull' \
  'docker run' \
  'docker-compose up' \
  'docker_compose up' \
  'mkdir' \
  'install' \
  'touch' \
  'chmod' \
  'chown' \
  'rm -' \
  'mv ' \
  'cp '; do
  if printf '%s\n' "$preflight_section" | grep -F "$forbidden_preflight_command" >/dev/null; then
    fail "read-only preflight contains: $forbidden_preflight_command"
  fi
done

require_text "$IMAGE_TEST" 'postgres:16-alpine@sha256:'
require_text "$IMAGE_TEST" 'redis:7-alpine@sha256:'
require_text "$IMAGE_TEST" 'backend_image_integration=ok'
require_text "$IMAGE_TEST" 'schema_migrations WHERE filename'
require_text "$IMAGE_TEST" '--network none --entrypoint /app/sub2api'
require_text "$IMAGE_TEST" 'production_baseline_image='
require_text "$IMAGE_TEST" 'image_only_rollback_compatibility=verified'
require_text "$IMAGE_TEST" "start_backend \"\$baseline\" \"\$CURRENT_IMAGE\""
require_text "$IMAGE_TEST" "start_backend \"\$candidate\" \"\$TARGET_IMAGE\""
require_text "$IMAGE_TEST" "start_backend \"\$rollback\" \"\$CURRENT_IMAGE\""
totp_test_key=$(sed -n 's/.*TOTP_ENCRYPTION_KEY=\([0-9a-f]*\).*/\1/p' "$IMAGE_TEST")
[ "${#totp_test_key}" -eq 64 ] \
  || fail "isolated backend TOTP encryption key must be 32-byte hex"

require_text "$SYNC_WORKFLOW" 'docker-content-digest:'
require_text "$SYNC_WORKFLOW" 'release_tag_object'
require_text "$SYNC_WORKFLOW" 'release_commit'
require_text "$SYNC_WORKFLOW" 'backend_image_digest'
require_text "$SYNC_WORKFLOW" 'backend_deploy_required'
require_text "$SYNC_WORKFLOW" 'expected_migrations'
require_text "$SYNC_WORKFLOW" '[State] AIFoo production backend'
require_text "$SYNC_WORKFLOW" 'unknown-production-baseline'
require_text "$SYNC_WORKFLOW" 'production-backend-changed-paths.txt'
require_text "$SYNC_WORKFLOW" 'pending manual owner-approved deployment'
reject_text "$SYNC_WORKFLOW" 'VPS_SSH_KEY'
reject_text "$SYNC_WORKFLOW" 'deploy-sub2api-backend'
reject_text "$SYNC_WORKFLOW" '.github/workflows/deploy-backend.yml'

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
rewrite_backend_service "$TEST_ROOT/docker-compose.yml" \
  "$TEST_ROOT/rewritten.yml" "weishaw/sub2api@$TEST_DIGEST"
require_text "$TEST_ROOT/rewritten.yml" "    image: weishaw/sub2api@$TEST_DIGEST"
require_text "$TEST_ROOT/rewritten.yml" '      - AUTO_SETUP=true'
require_text "$TEST_ROOT/rewritten.yml" '      - ./data:/app/data'
require_text "$TEST_ROOT/rewritten.yml" '    image: nginx:stable'
[ "$(grep -c '^    image: weishaw/sub2api@' "$TEST_ROOT/rewritten.yml")" -eq 1 ] \
  || fail "backend rewrite changed more than one image"

validate_digest "$TEST_DIGEST"
validate_release_tag v0.1.170
validate_commit c043c24774228ba891ddf90d783aa6dc7d0855b5
validate_migrations 192_group_profit_control.sql,193_group_profit_control_auth_cache_invalidation.sql
validate_migrations none
if (validate_migrations '../../escape.sql') >/dev/null 2>&1; then
  fail "unsafe migration input was accepted"
fi

TEST_RELEASE=v0.1.170
TEST_COMMIT=c043c24774228ba891ddf90d783aa6dc7d0855b5
TEST_MIGRATIONS=192_group_profit_control.sql,193_group_profit_control_auth_cache_invalidation.sql
TEST_BACKUP_ID=20260803-120000-abcdef-backend-v0.1.170
PREVIOUS_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TARGET_IMAGE_ID=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
ORIGINAL_COMPOSE_SHA=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
CANDIDATE_COMPOSE_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ROLLBACK_COMPOSE_SHA=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
TEST_BACKUP_DIR=$AIFOO_BACKUP_ROOT/$TEST_BACKUP_ID
mkdir -p "$TEST_BACKUP_DIR" "$TEST_ROOT/bin"

cp "$TEST_ROOT/docker-compose.yml" "$TEST_BACKUP_DIR/docker-compose.yml"
cp "$TEST_ROOT/docker-compose.yml" "$TEST_BACKUP_DIR/candidate-compose.yml"
cp "$TEST_ROOT/docker-compose.yml" "$TEST_BACKUP_DIR/rollback-compose.yml"
printf '# candidate image\n' >> "$TEST_BACKUP_DIR/candidate-compose.yml"
printf '# rollback image\n' >> "$TEST_BACKUP_DIR/rollback-compose.yml"
ORIGINAL_COMPOSE_SHA=$(sha256sum "$TEST_BACKUP_DIR/docker-compose.yml" | awk '{print $1}')
CANDIDATE_COMPOSE_SHA=$(sha256sum "$TEST_BACKUP_DIR/candidate-compose.yml" | awk '{print $1}')
ROLLBACK_COMPOSE_SHA=$(sha256sum "$TEST_BACKUP_DIR/rollback-compose.yml" | awk '{print $1}')

cat > "$TEST_BACKUP_DIR/metadata.env" <<EOF
backup_id=$TEST_BACKUP_ID
target_digest=$TEST_DIGEST
target_release=$TEST_RELEASE
target_commit=$TEST_COMMIT
target_image_id=$TARGET_IMAGE_ID
expected_migrations=$TEST_MIGRATIONS
previous_image_ref=weishaw/sub2api:old
previous_image_id=$PREVIOUS_IMAGE_ID
previous_version=0.1.169
previous_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rollback_image_ref=aifoo/sub2api-backend-rollback:$TEST_BACKUP_ID
rollback_image_id=$PREVIOUS_IMAGE_ID
compose_sha256=$ORIGINAL_COMPOSE_SHA
candidate_compose_sha256=$CANDIDATE_COMPOSE_SHA
rollback_compose_sha256=$ROLLBACK_COMPOSE_SHA
EOF
printf 'backend image archive\n' > "$TEST_BACKUP_DIR/backend-image.tar"
printf 'frontend|postgres|redis signatures\n' > "$TEST_BACKUP_DIR/companion-containers.txt"
printf '001_bootstrap.sql\tchecksum\tapplied\n' > "$TEST_BACKUP_DIR/schema-migrations.tsv"
printf 'postgres custom dump\n' > "$TEST_BACKUP_DIR/postgres.dump"
printf 'postgres globals\n' > "$TEST_BACKUP_DIR/postgres-globals.sql"
printf 'redis rdb\n' > "$TEST_BACKUP_DIR/redis.rdb"
printf 'backend data archive\n' > "$TEST_BACKUP_DIR/backend-data.tar.gz"
write_backup_checksums() {
  (
    cd "$TEST_BACKUP_DIR"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
  ) > "$TEST_ROOT/backup-checksums"
  mv "$TEST_ROOT/backup-checksums" "$TEST_BACKUP_DIR/SHA256SUMS"
}
write_backup_checksums
cat > "$DEPLOYMENT_STATE_FILE" <<EOF
digest=$TEST_DIGEST
backup_id=$TEST_BACKUP_ID
EOF
cat > "$TEST_ROOT/bin/docker-compose" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$TEST_ROOT/bin/docker-compose"
PATH=$TEST_ROOT/bin:$PATH
export PATH

CURRENT_IMAGE_ID=$TARGET_IMAGE_ID
CURRENT_COMPOSE_SHA=$CANDIDATE_COMPOSE_SHA
RESTORE_FAILURE=

container_field() {
  printf '%s\n' "$CURRENT_IMAGE_ID"
}

compose_sha256() {
  printf '%s\n' "$CURRENT_COMPOSE_SHA"
}

docker() {
  if [ "${1:-}" = "image" ] && [ "${2:-}" = "load" ]; then
    [ "$RESTORE_FAILURE" != "image_load" ]
    return
  fi
  if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
    case "${3:-}" in
      aifoo/sub2api-backend-rollback:*) printf '%s\n' "$PREVIOUS_IMAGE_ID" ;;
      *) return 1 ;;
    esac
    return
  fi
  return 1
}

docker_compose() {
  [ "$RESTORE_FAILURE" != "compose_start" ] \
    && [ "$RESTORE_FAILURE" != "idempotent_must_not_restart" ]
}

verify_backend_health() {
  [ "$RESTORE_FAILURE" != "rollback_health" ]
}

verify_companions_unchanged() {
  return 0
}

if restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" 20260803-120000-fedcba-backend-v0.1.170 >/dev/null 2>&1; then
  fail "restore succeeded without a verified backup"
fi

mv "$TEST_BACKUP_DIR/postgres.dump" "$TEST_ROOT/postgres.dump"
if require_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
  fail "backup validation accepted a missing PostgreSQL dump"
fi
mv "$TEST_ROOT/postgres.dump" "$TEST_BACKUP_DIR/postgres.dump"

cp "$TEST_BACKUP_DIR/candidate-compose.yml" "$TEST_ROOT/candidate-compose.yml"
printf '# metadata drift\n' >> "$TEST_BACKUP_DIR/candidate-compose.yml"
write_backup_checksums
if require_backup "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
  fail "backup validation accepted Compose metadata drift"
fi
mv "$TEST_ROOT/candidate-compose.yml" "$TEST_BACKUP_DIR/candidate-compose.yml"
write_backup_checksums

if (
  # shellcheck disable=SC2329
  require_backup() {
    return 1
  }
  restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
    "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1
); then
  fail "restore ignored an explicit require_backup failure"
fi

for RESTORE_FAILURE in image_load compose_start rollback_health; do
  CURRENT_IMAGE_ID=$TARGET_IMAGE_ID
  CURRENT_COMPOSE_SHA=$CANDIDATE_COMPOSE_SHA
  if restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
    "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
    fail "restore incorrectly succeeded after $RESTORE_FAILURE failure"
  fi
done

RESTORE_FAILURE=
CURRENT_IMAGE_ID=$PREVIOUS_IMAGE_ID
CURRENT_COMPOSE_SHA=$CANDIDATE_COMPOSE_SHA
if ! restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
  fail "restore rejected the old container with the verified candidate Compose"
fi

CURRENT_IMAGE_ID=$TARGET_IMAGE_ID
CURRENT_COMPOSE_SHA=$ROLLBACK_COMPOSE_SHA
if ! restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
  fail "restore rejected the target container with the verified rollback Compose"
fi

RESTORE_FAILURE=idempotent_must_not_restart
CURRENT_IMAGE_ID=$PREVIOUS_IMAGE_ID
CURRENT_COMPOSE_SHA=$ROLLBACK_COMPOSE_SHA
if ! restore_image "$TEST_DIGEST" "$TEST_RELEASE" "$TEST_COMMIT" \
  "$TEST_MIGRATIONS" "$TEST_BACKUP_ID" >/dev/null 2>&1; then
  fail "an already-restored backend was not treated as an idempotent success"
fi

echo "backend_workflow_contract=ok"
