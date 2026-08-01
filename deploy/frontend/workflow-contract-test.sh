#!/bin/sh

# shellcheck disable=SC1090,SC2016

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
SYNC_WORKFLOW=$ROOT/.github/workflows/upstream-sync.yml
VALIDATE_WORKFLOW=$ROOT/.github/workflows/validate.yml
DEPLOY_WORKFLOW=$ROOT/.github/workflows/deploy.yml
DEPLOY_HELPER=$ROOT/deploy/frontend/deploy-frontend.sh

fail() {
  echo "workflow contract test failed: $1" >&2
  exit 1
}

require_text() {
  file=$1
  text=$2
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

require_text "$SYNC_WORKFLOW" 'repos/$official_repo/releases/latest'
require_text "$SYNC_WORKFLOW" 'refs/tags/$tag:refs/tags/$tag'
require_text "$SYNC_WORKFLOW" "prerelease"
require_text "$SYNC_WORKFLOW" "ui-review-required"
require_text "$SYNC_WORKFLOW" "backend_contract=true"
require_text "$SYNC_WORKFLOW" "approve_ui"
require_text "$SYNC_WORKFLOW" "retry_final"
require_text "$SYNC_WORKFLOW" 'current_base=$(gh api'
require_text "$SYNC_WORKFLOW" 'git merge-base --is-ancestor "$release_commit" "$candidate_sha"'
require_text "$SYNC_WORKFLOW" '-F force=false'
require_text "$SYNC_WORKFLOW" 'needs.prepare.outputs.final_retry'
require_text "$SYNC_WORKFLOW" 'backend/internal/(domain|middleware|model|pkg/response|setup)/'
require_text "$SYNC_WORKFLOW" "ready-for-vps"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/backend-ci.yml"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/security-scan.yml"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/validate.yml"
require_text "$SYNC_WORKFLOW" "publish_image: true"

if grep -Eq 'git fetch .*upstream main|refs/remotes/upstream/main' "$SYNC_WORKFLOW"; then
  fail "stable release sync must not fetch or mirror upstream main"
fi
if grep -Fq 'gh pr merge' "$SYNC_WORKFLOW"; then
  fail "stable release sync must use an atomic non-force production ref update"
fi

require_text "$VALIDATE_WORKFLOW" "file: deploy/frontend/Dockerfile"
require_text "$VALIDATE_WORKFLOW" "Run container smoke tests"
require_text "$VALIDATE_WORKFLOW" "Full frontend Vitest suite"
require_text "$VALIDATE_WORKFLOW" "Publish the smoke-tested image"
require_text "$VALIDATE_WORKFLOW" "Download the smoke-tested image"
require_text "$VALIDATE_WORKFLOW" "sub2api-frontend:candidate-"
if grep -Fq "file: Dockerfile" "$VALIDATE_WORKFLOW"; then
  fail "AIFoo validation must not build the full backend image"
fi

require_text "$DEPLOY_HELPER" 'backup)'
require_text "$DEPLOY_HELPER" 'require_backup "$digest" "$backup_id"'
require_text "$DEPLOY_HELPER" 'docker image save --output "$backup_work_dir/frontend-image.tar"'
require_text "$DEPLOY_HELPER" 'docker commit "$PRODUCTION_CONTAINER" "$snapshot_base_ref"'
require_text "$DEPLOY_HELPER" 'COPY --chown=0:0 nginx/ /etc/nginx/'
require_text "$DEPLOY_HELPER" 'rollback_image_id='
require_text "$DEPLOY_HELPER" 'sha256sum -c SHA256SUMS'
require_text "$DEPLOY_HELPER" 'deploy_digest "${2:-}" "${3:-}"'
require_text "$DEPLOY_HELPER" 'restore_backup "${2:-}" "${3:-}"'
require_text "$DEPLOY_HELPER" 'previous_compose_sha256='
require_text "$DEPLOY_HELPER" 'candidate_compose_sha256='
require_text "$DEPLOY_HELPER" 'rollback_compose_sha256='
require_text "$DEPLOY_HELPER" 'mount-destinations.txt'
require_text "$DEPLOY_HELPER" 'trap restore_interrupted_deploy HUP INT TERM'
require_text "$DEPLOY_HELPER" 'verify_production "$rollback_image_id" legacy'

backup_line=$(grep -n 'name: Back up the current frontend' "$DEPLOY_WORKFLOW" | cut -d: -f1)
deploy_line=$(grep -n 'name: Deploy the staged digest after verified backup' "$DEPLOY_WORKFLOW" | cut -d: -f1)
[ -n "$backup_line" ] || fail "deploy workflow has no backup step"
[ -n "$deploy_line" ] || fail "deploy workflow has no guarded deploy step"
[ "$backup_line" -lt "$deploy_line" ] || fail "backup must run before deployment"
require_text "$DEPLOY_WORKFLOW" 'steps.backup.outputs.backup_id'
require_text "$DEPLOY_WORKFLOW" 'Restore the backup after a failed deployment check'
require_text "$DEPLOY_WORKFLOW" 'deploy-sub2api-frontend restore'
require_text "$DEPLOY_WORKFLOW" 'landing_html=$(curl --fail --location'

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-deploy-contract.XXXXXX")
cleanup_test_root() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/aifoo-deploy-contract.*)
      rm -rf -- "$TEST_ROOT"
      ;;
  esac
}
trap cleanup_test_root EXIT HUP INT TERM

install -d "$TEST_ROOT/app" "$TEST_ROOT/backups"
cat > "$TEST_ROOT/app/docker-compose.yml" <<'EOF'
services:
  frontend:
    image: nginx:stable
    volumes:
      - ./landing:/usr/share/nginx/html:ro
    ports:
      - 127.0.0.1:8080:8080
  sub2api:
    image: sub2api:stable
EOF

AIFOO_DEPLOY_LIBRARY_ONLY=1
AIFOO_APP_DIR=$TEST_ROOT/app
AIFOO_BACKUP_ROOT=$TEST_ROOT/backups
AIFOO_IMAGE_REPOSITORY=ghcr.io/example/sub2api-frontend
export AIFOO_DEPLOY_LIBRARY_ONLY AIFOO_APP_DIR AIFOO_BACKUP_ROOT AIFOO_IMAGE_REPOSITORY
. "$DEPLOY_HELPER"

OLD_IMAGE_ID=sha256:$(printf '1%.0s' $(seq 1 64))
REQUESTED_IMAGE_ID=sha256:$(printf '2%.0s' $(seq 1 64))
ROLLBACK_IMAGE_ID=sha256:$(printf '3%.0s' $(seq 1 64))
UNRELATED_IMAGE_ID=sha256:$(printf '4%.0s' $(seq 1 64))
TEST_DIGEST=sha256:$(printf 'a%.0s' $(seq 1 64))
MOCK_CURRENT_IMAGE_ID=$OLD_IMAGE_ID
MOCK_STATUS=state:running
MOCK_LOADED_ROLLBACK_ID=$ROLLBACK_IMAGE_ID
MOCK_FRONTEND_HEALTH_AVAILABLE=false
MOCK_MOUNTS='/etc/nginx/conf.d/default.conf
/usr/share/nginx/html'

require_staged_digest() {
  :
}

docker() {
  if [ "$1" = "container" ] && [ "$2" = "inspect" ]; then
    echo '{"State":{"Status":"running"}}'
    return 0
  fi

  if [ "$1" = "inspect" ]; then
    case "${4:-}" in
      *State.Health*) printf '%s\n' "$MOCK_STATUS" ;;
      *Mounts*) printf '%s\n' "$MOCK_MOUNTS" ;;
      *Config.Image*) echo 'nginx:stable' ;;
      *Config.User*) echo '' ;;
      *Image*) printf '%s\n' "$MOCK_CURRENT_IMAGE_ID" ;;
      *) echo '{}' ;;
    esac
    return 0
  fi

  if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
    target=$3
    if [ "${4:-}" = "--format" ]; then
      case "$target" in
        aifoo-frontend-rollback:*) printf '%s\n' "$MOCK_LOADED_ROLLBACK_ID" ;;
        "$IMAGE_REPOSITORY@$TEST_DIGEST") printf '%s\n' "$REQUESTED_IMAGE_ID" ;;
        *) printf '%s\n' "$target" ;;
      esac
    else
      echo '[{"Id":"mock"}]'
    fi
    return 0
  fi

  if [ "$1" = "image" ] && [ "$2" = "save" ]; then
    printf 'mock rollback image\n' > "$4"
    return 0
  fi
  if [ "$1" = "image" ] && { [ "$2" = "load" ] || [ "$2" = "rm" ]; }; then
    return 0
  fi
  if [ "$1" = "cp" ]; then
    case "$2" in
      *:/etc/nginx/.) printf 'events {}\n' > "$3/nginx.conf" ;;
      *:/usr/share/nginx/html/.) printf '<div id="app"></div>\n' > "$3/index.html" ;;
    esac
    return 0
  fi
  if [ "$1" = "commit" ]; then
    printf '%s\n' "$3" >> "$TEST_ROOT/commits"
    return 0
  fi
  if [ "$1" = "build" ]; then
    printf 'built\n' >> "$TEST_ROOT/builds"
    return 0
  fi
  if [ "$1" = "pull" ] || [ "$1" = "logs" ]; then
    return 0
  fi

  echo "unexpected docker invocation: $*" >&2
  return 1
}

docker_compose() {
  if [ "$1" = "-f" ]; then
    if [ -f "$TEST_ROOT/fail-next-config" ]; then
      rm "$TEST_ROOT/fail-next-config"
      return 1
    fi
    return 0
  fi
  if [ "$1" = "up" ]; then
    if [ -f "$TEST_ROOT/fail-next-up" ]; then
      rm "$TEST_ROOT/fail-next-up"
      return 1
    fi
    if grep -q 'image: aifoo-frontend-rollback:' "$COMPOSE_FILE"; then
      MOCK_CURRENT_IMAGE_ID=$ROLLBACK_IMAGE_ID
      printf 'rollback\n' >> "$TEST_ROOT/compose-up"
    else
      MOCK_CURRENT_IMAGE_ID=$REQUESTED_IMAGE_ID
      printf 'candidate\n' >> "$TEST_ROOT/compose-up"
    fi
    return 0
  fi
  echo "unexpected docker-compose invocation: $*" >&2
  return 1
}

curl() {
  last=
  for arg in "$@"; do
    last=$arg
  done
  case "$last" in
    */frontend-health)
      if [ "$MOCK_FRONTEND_HEALTH_AVAILABLE" != "true" ]; then
        return 1
      fi
      echo '{"status":"ok"}'
      ;;
    */health) echo '{"status":"ok"}' ;;
  esac
  return 0
}

sleep() {
  :
}

expect_failure() {
  description=$1
  shift
  if ("$@") >/dev/null 2>&1; then
    fail "$description"
  fi
}

expect_failure "strict candidate verification accepted a container without HEALTHCHECK" \
  verify_production "$OLD_IMAGE_ID" strict

first_output=$(create_backup "$TEST_DIGEST")
first_backup_id=$(printf '%s\n' "$first_output" | sed -n 's/^backup_id=//p' | tail -n 1)
validate_backup_id "$first_backup_id"
first_backup_dir=$BACKUP_ROOT/$first_backup_id
[ -s "$first_backup_dir/frontend-image.tar" ] || fail "backup image archive was not created"
[ -s "$first_backup_dir/nginx/nginx.conf" ] || fail "running Nginx state was not captured"
[ -s "$first_backup_dir/html/index.html" ] || fail "running HTML state was not captured"
[ -s "$first_backup_dir/candidate-compose.yml" ] || fail "candidate Compose was not recorded"
[ -s "$first_backup_dir/rollback-compose.yml" ] || fail "rollback Compose was not recorded"
require_backup "$TEST_DIGEST" "$first_backup_id"

MOCK_MOUNTS=/etc/ssl/private
expect_failure "unsupported frontend mount was accepted" create_backup "$TEST_DIGEST"
MOCK_MOUNTS='/etc/nginx/conf.d/default.conf
/usr/share/nginx/html'

second_output=$(create_backup "$TEST_DIGEST")
second_backup_id=$(printf '%s\n' "$second_output" | sed -n 's/^backup_id=//p' | tail -n 1)
[ "$first_backup_id" != "$second_backup_id" ] \
  || fail "two backups created in the same second reused an ID"
second_backup_dir=$BACKUP_ROOT/$second_backup_id

printf '# corrupt\n' >> "$first_backup_dir/docker-compose.yml"
expect_failure "corrupted backup checksum was accepted" \
  require_backup "$TEST_DIGEST" "$first_backup_id"

MOCK_CURRENT_IMAGE_ID=$UNRELATED_IMAGE_ID
expect_failure "stale backup was accepted for an unrelated production image" \
  require_backup "$TEST_DIGEST" "$second_backup_id" restore

MOCK_CURRENT_IMAGE_ID=$REQUESTED_IMAGE_ID
cp "$second_backup_dir/candidate-compose.yml" "$COMPOSE_FILE"
expect_failure "same-digest backup without its deployment state was accepted" \
  require_backup "$TEST_DIGEST" "$second_backup_id" restore
write_deployment_state "$TEST_DIGEST" "$first_backup_id"
expect_failure "same-digest backup with another deployment state was accepted" \
  require_backup "$TEST_DIGEST" "$second_backup_id" restore

compose_before_failed_restore=$(compose_sha256 "$COMPOSE_FILE")
: > "$TEST_ROOT/fail-next-config"
expect_failure "invalid rollback Compose configuration was accepted" \
  rollback_and_verify "$second_backup_dir"
[ "$(compose_sha256 "$COMPOSE_FILE")" = "$compose_before_failed_restore" ] \
  || fail "failed rollback Compose validation replaced the production Compose file"

write_deployment_state "$TEST_DIGEST" "$second_backup_id"
restore_backup "$TEST_DIGEST" "$second_backup_id" >/dev/null
require_backup "$TEST_DIGEST" "$second_backup_id" restore
grep -q 'image: aifoo-frontend-rollback:' "$COMPOSE_FILE" \
  || fail "restore did not pin the verified rollback image"
if grep -q '^    volumes:' "$COMPOSE_FILE"; then
  fail "restore retained mutable frontend bind mounts"
fi
compose_up_before_repeat=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
restore_backup "$TEST_DIGEST" "$second_backup_id" >/dev/null
compose_up_after_repeat=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
[ "$compose_up_before_repeat" = "$compose_up_after_repeat" ] \
  || fail "idempotent restore recreated an already restored frontend"

MOCK_CURRENT_IMAGE_ID=$REQUESTED_IMAGE_ID
MOCK_LOADED_ROLLBACK_ID=$UNRELATED_IMAGE_ID
expect_failure "rollback image ID mismatch was accepted" \
  rollback_and_verify "$second_backup_dir"
MOCK_LOADED_ROLLBACK_ID=$ROLLBACK_IMAGE_ID

cp "$second_backup_dir/docker-compose.yml" "$COMPOSE_FILE"
MOCK_CURRENT_IMAGE_ID=$OLD_IMAGE_ID
MOCK_STATUS=health:healthy
MOCK_FRONTEND_HEALTH_AVAILABLE=true
: > "$TEST_ROOT/fail-next-up"
expect_failure "failed candidate deployment reported success" \
  deploy_digest "$TEST_DIGEST" "$second_backup_id"
grep -q '^rollback$' "$TEST_ROOT/compose-up" \
  || fail "failed candidate deployment did not restore the backup"

echo "workflow_contract=ok"
