#!/bin/sh

# shellcheck disable=SC1090,SC2016

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
SYNC_WORKFLOW=$ROOT/.github/workflows/upstream-sync.yml
VALIDATE_WORKFLOW=$ROOT/.github/workflows/validate.yml
RELEASE_WORKFLOW=$ROOT/.github/workflows/release.yml
BACKEND_CI_WORKFLOW=$ROOT/.github/workflows/backend-ci.yml
SECURITY_WORKFLOW=$ROOT/.github/workflows/security-scan.yml
MACOS_SHELL_WORKFLOW=$ROOT/.github/workflows/macos-shell-ci.yml
DEPLOY_WORKFLOW=$ROOT/.github/workflows/deploy.yml
BACKEND_DEPLOY_WORKFLOW=$ROOT/.github/workflows/deploy-backend.yml
BACKEND_PREPARATION_WORKFLOW=$ROOT/.github/workflows/backend-preparation.yml
WEB_UPDATE_WORKFLOW=$ROOT/.github/workflows/web-update.yml
FRONTEND_ACTIVATION_WORKFLOW=$ROOT/.github/workflows/frontend-activation.yml
PREFLIGHT_WORKFLOW=$ROOT/.github/workflows/preflight.yml
CLA_WORKFLOW=$ROOT/.github/workflows/cla.yml
DEPLOY_HELPER=$ROOT/deploy/frontend/deploy-frontend.sh
DOCKER_INTEGRATION=$ROOT/deploy/frontend/docker-workflow-integration-test.sh
NGINX_CONFIG=$ROOT/deploy/frontend/nginx.conf
SECURITY_HEADERS=$ROOT/deploy/frontend/security-headers.conf
ROOT_DOCKERFILE=$ROOT/Dockerfile
DEPLOY_DOCKERFILE=$ROOT/deploy/Dockerfile
FRONTEND_DOCKERFILE=$ROOT/deploy/frontend/Dockerfile
UPDATE_BRIDGE=$ROOT/deploy/update-bridge/main.go
UPDATE_BRIDGE_SERVICE=$ROOT/deploy/update-bridge/aifoo-update-bridge.service
UPDATE_BRIDGE_INSTALL=$ROOT/deploy/update-bridge/install.sh
UPDATE_BRIDGE_NGINX=$ROOT/deploy/update-bridge/nginx-location.conf

fail() {
  echo "workflow contract test failed: $1" >&2
  exit 1
}

require_text() {
  file=$1
  text=$2
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

reject_text() {
  file=$1
  text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file contains forbidden text: $text"
  fi
}

require_runner_only() {
  file=$1
  runner=$2
  total=$(grep -Ec '^[[:space:]]+runs-on:' "$file")
  matching=$(grep -Fc -- "runs-on: $runner" "$file")
  [ "$total" -gt 0 ] || fail "$file has no direct runner jobs"
  [ "$total" -eq "$matching" ] \
    || fail "$file contains a runner outside the required policy: $runner"
}

reject_trigger() {
  file=$1
  trigger=$2
  if sed -n '1,/^permissions:/p' "$file" \
    | grep -Eq "^[[:space:]]{2}${trigger}:"; then
    fail "$file contains forbidden trigger: $trigger"
  fi
}

require_text "$SYNC_WORKFLOW" 'repos/$official_repo/releases/latest'
require_text "$SYNC_WORKFLOW" 'refs/tags/$tag:refs/tags/$tag'
require_text "$SYNC_WORKFLOW" "prerelease"
require_text "$SYNC_WORKFLOW" "ui-review-required"
require_text "$SYNC_WORKFLOW" "backend_contract=true"
reject_text "$SYNC_WORKFLOW" "approve_ui"
reject_text "$SYNC_WORKFLOW" '--add-label ui-review-required'
require_text "$SYNC_WORKFLOW" 'The deterministic compatibility policy approved the locked-base merge'
require_text "$SYNC_WORKFLOW" 'newly added upstream surfaces retain their official UI by default'
require_text "$SYNC_WORKFLOW" "retry_final"
require_text "$SYNC_WORKFLOW" 'current_base=$(gh api'
require_text "$SYNC_WORKFLOW" 'git merge-base --is-ancestor "$release_commit" "$candidate_sha"'
require_text "$SYNC_WORKFLOW" '-F force=false'
require_text "$SYNC_WORKFLOW" 'needs.prepare.outputs.final_retry'
require_text "$SYNC_WORKFLOW" 'backend/internal/(domain|middleware|model|pkg/response|setup)/'
require_text "$SYNC_WORKFLOW" "ready-for-vps"
require_text "$SYNC_WORKFLOW" "vps-preloaded"
require_text "$SYNC_WORKFLOW" "preload_frontend:"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/frontend-activation.yml"
require_text "$SYNC_WORKFLOW" "prepare_backend:"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/backend-preparation.yml"
require_text "$SYNC_WORKFLOW" "ready_for_update:"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/backend-ci.yml"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/security-scan.yml"
require_text "$SYNC_WORKFLOW" "uses: ./.github/workflows/validate.yml"
require_text "$SYNC_WORKFLOW" "publish_image: true"
require_text "$SYNC_WORKFLOW" "publish_candidate: true"
require_text "$SYNC_WORKFLOW" 'needs.candidate_frontend.outputs.image_digest'
require_text "$SYNC_WORKFLOW" 'needs.recover_final.outputs.reusable'
require_text "$SYNC_WORKFLOW" "Candidate image evidence is invalid; a necessary rebuild will run"
require_text "$SYNC_WORKFLOW" "The exact validated candidate image is now being finalized without rebuilding."
reject_text "$SYNC_WORKFLOW" "final_frontend:"
require_text "$SYNC_WORKFLOW" "group: aifoo-production-mutation"
require_text "$SYNC_WORKFLOW" "statuses: write"
require_text "$SYNC_WORKFLOW" "# Every 3 hours, offset from busy whole-hour slots (Asia/Shanghai 02:17, 05:17, ...)."
require_text "$SYNC_WORKFLOW" "- cron: '17 */3 * * *'"

VM_RUNNER='[self-hosted, linux, x64, aifoo-vm]'
GITHUB_RUNNER='ubuntu-latest'
for workflow in \
  "$SYNC_WORKFLOW" \
  "$BACKEND_CI_WORKFLOW" \
  "$SECURITY_WORKFLOW" \
  "$VALIDATE_WORKFLOW" \
  "$BACKEND_DEPLOY_WORKFLOW" \
  "$BACKEND_PREPARATION_WORKFLOW" \
  "$WEB_UPDATE_WORKFLOW" \
  "$FRONTEND_ACTIVATION_WORKFLOW"; do
  require_runner_only "$workflow" "$VM_RUNNER"
done
for workflow in \
  "$PREFLIGHT_WORKFLOW" \
  "$DEPLOY_WORKFLOW" \
  "$CLA_WORKFLOW"; do
  require_runner_only "$workflow" "$GITHUB_RUNNER"
done
require_text "$BACKEND_CI_WORKFLOW" "if: inputs.checkout_ref != '' && inputs.run_macos"

for file in \
  "$WEB_UPDATE_WORKFLOW" \
  "$FRONTEND_ACTIVATION_WORKFLOW" \
  "$UPDATE_BRIDGE" \
  "$UPDATE_BRIDGE_SERVICE" \
  "$UPDATE_BRIDGE_INSTALL" \
  "$UPDATE_BRIDGE_NGINX"; do
  [ -s "$file" ] || fail "required web update file is missing: $file"
done

require_text "$DEPLOY_WORKFLOW" 'workflow_call:'
require_text "$BACKEND_DEPLOY_WORKFLOW" 'workflow_call:'
require_text "$WEB_UPDATE_WORKFLOW" 'workflow_dispatch:'
require_text "$WEB_UPDATE_WORKFLOW" 'Only the repository owner can approve a web update'
require_text "$WEB_UPDATE_WORKFLOW" 'ready-for-vps'
require_text "$WEB_UPDATE_WORKFLOW" 'ui-review-required sync-failed vps-preload-failed'
require_text "$WEB_UPDATE_WORKFLOW" 'uses: ./.github/workflows/deploy-backend.yml'
require_text "$WEB_UPDATE_WORKFLOW" 'uses: ./.github/workflows/frontend-activation.yml'
require_text "$WEB_UPDATE_WORKFLOW" 'mode: activate'
require_text "$WEB_UPDATE_WORKFLOW" 'secrets: inherit'
require_text "$WEB_UPDATE_WORKFLOW" 'approval: DEPLOY-AIFOO-BACKEND'
require_text "$WEB_UPDATE_WORKFLOW" 'backend-prepared'
require_text "$WEB_UPDATE_WORKFLOW" 'expected_migrations:'
require_text "$WEB_UPDATE_WORKFLOW" 'vps-deployed'
require_text "$WEB_UPDATE_WORKFLOW" 'web-update-failed'
require_text "$WEB_UPDATE_WORKFLOW" 'web-update-running'
require_text "$WEB_UPDATE_WORKFLOW" 'group: aifoo-web-update-orchestration'
require_text "$WEB_UPDATE_WORKFLOW" 'GH_REPO: ${{ github.repository }}'
require_text "$WEB_UPDATE_WORKFLOW" '.user.login == "github-actions[bot]"'
require_text "$WEB_UPDATE_WORKFLOW" '($owner | ascii_downcase)'
require_text "$WEB_UPDATE_WORKFLOW" 'Remote validation completed'
require_text "$WEB_UPDATE_WORKFLOW" 'backend-deployed is not backed by the exact production State Issue'
require_text "$WEB_UPDATE_WORKFLOW" 'vps-preloaded'
reject_text "$WEB_UPDATE_WORKFLOW" 'schedule:'

require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'workflow_call:'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'name: Validate requested operation'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'mode must be preload or activate'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" "inputs.mode == 'preload'"
require_text "$FRONTEND_ACTIVATION_WORKFLOW" "inputs.mode == 'activate'"
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'cd /opt/sub2api && sudo /usr/local/sbin/deploy-sub2api-frontend activate'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'vps-preload-failed'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'compare/$SOURCE_SHA...$production_sha'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'Frontend image inputs changed after the validated image was built'
preload_validation=$(sed -n \
  '/name: Validate the exact approved candidate/,/name: Reconfirm the preloaded activation target/p' \
  "$FRONTEND_ACTIVATION_WORKFLOW")
if printf '%s\n' "$preload_validation" | grep -Fq 'grep -Fxq ready-for-vps'; then
  fail 'frontend preload must complete before ready-for-vps is added'
fi
activation_validation=$(sed -n \
  '/name: Reconfirm the preloaded activation target/,/name: Checkout the approved production revision/p' \
  "$FRONTEND_ACTIVATION_WORKFLOW")
printf '%s\n' "$activation_validation" | grep -Fq 'ready-for-vps vps-preloaded' \
  || fail 'frontend activation must require ready-for-vps and vps-preloaded'
printf '%s\n' "$activation_validation" | grep -Fq 'backend-deploy-required' \
  || fail 'frontend activation must wait for required backend activation'
require_text "$FRONTEND_ACTIVATION_WORKFLOW" 'The web button remains hidden until all required preparation finishes.'

require_text "$UPDATE_BRIDGE" 'defaultListenAddr = "127.0.0.1:8091"'
require_text "$UPDATE_BRIDGE" 'defaultAdminURL   = "http://127.0.0.1:8080/api/v1/admin/system/version"'
require_text "$UPDATE_BRIDGE" 'AIFOO_UPGRADE_GITHUB_TOKEN_FILE'
require_text "$UPDATE_BRIDGE" 'os.ReadFile(tokenFile)'
require_text "$UPDATE_BRIDGE" '"ref": "production"'
require_text "$UPDATE_BRIDGE" 'defaultWorkflow   = "web-update.yml"'
require_text "$UPDATE_BRIDGE" 'result.BackendRequired && !labels["backend-prepared"]'
require_text "$UPDATE_BRIDGE" 'labels["web-update-running"] || s.isPending(tag)'
require_text "$UPDATE_BRIDGE" 'run.Conclusion == "success" && labels["vps-deployed"]'
require_text "$UPDATE_BRIDGE_SERVICE" 'User=aifoo-update-bridge'
require_text "$UPDATE_BRIDGE_NGINX" 'location = /api/v1/aifoo-upgrade/status'
require_text "$UPDATE_BRIDGE_NGINX" 'location = /api/v1/aifoo-upgrade/dispatch'
sh -n "$UPDATE_BRIDGE_INSTALL"

if grep -R -E 'AIFOO_UPGRADE_GITHUB_TOKEN(_FILE)?|/etc/aifoo-update-bridge/github-token' \
  "$ROOT/frontend" "$ROOT/.github/workflows" >/dev/null 2>&1; then
  fail 'GitHub PAT configuration must not enter frontend or Actions workflows'
fi

if grep -Eq 'git fetch .*upstream main|refs/remotes/upstream/main' "$SYNC_WORKFLOW"; then
  fail "stable release sync must not fetch or mirror upstream main"
fi
if grep -Fq 'gh pr merge' "$SYNC_WORKFLOW"; then
  fail "stable release sync must use an atomic non-force production ref update"
fi

require_text "$VALIDATE_WORKFLOW" "file: deploy/frontend/Dockerfile"
reject_trigger "$VALIDATE_WORKFLOW" push
require_text "$VALIDATE_WORKFLOW" "Run container smoke tests"
require_text "$VALIDATE_WORKFLOW" "Full frontend Vitest suite"
require_text "$VALIDATE_WORKFLOW" "Publish the smoke-tested image"
require_text "$VALIDATE_WORKFLOW" "Download the smoke-tested image"
require_text "$VALIDATE_WORKFLOW" "sub2api-frontend:candidate-"
require_text "$VALIDATE_WORKFLOW" "publish_candidate=true requires publish_image=true"
require_text "$VALIDATE_WORKFLOW" "Candidate publication requires one exact open upgrade PR targeting production"
require_text "$VALIDATE_WORKFLOW" "Run deployment backup and restore integration"
require_text "$VALIDATE_WORKFLOW" "Record exact production validation"
require_text "$VALIDATE_WORKFLOW" "aifoo/frontend-validation"
require_text "$VALIDATE_WORKFLOW" "statuses: write"
if grep -Fq "file: Dockerfile" "$VALIDATE_WORKFLOW"; then
  fail "AIFoo validation must not build the full backend image"
fi

require_text "$RELEASE_WORKFLOW" "workflow_dispatch:"
require_text "$RELEASE_WORKFLOW" "uses: ./.github/workflows/security-scan.yml"
require_text "$RELEASE_WORKFLOW" "uses: ./.github/workflows/validate.yml"
require_text "$RELEASE_WORKFLOW" "needs: security"
require_text "$RELEASE_WORKFLOW" "publish_image: true"
require_text "$RELEASE_WORKFLOW" "statuses: write"
require_text "$RELEASE_WORKFLOW" 'checkout_ref: ${{ github.sha }}'
reject_text "$RELEASE_WORKFLOW" "push:"
reject_text "$RELEASE_WORKFLOW" "tags:"
reject_text "$RELEASE_WORKFLOW" "goreleaser"
reject_text "$RELEASE_WORKFLOW" "DockerHub"
reject_text "$RELEASE_WORKFLOW" "backend/"
reject_text "$RELEASE_WORKFLOW" "contents: write"

require_text "$ROOT_DOCKERFILE" 'frontend/pnpm-workspace.yaml'
require_text "$DEPLOY_DOCKERFILE" 'frontend/pnpm-workspace.yaml'
require_text "$FRONTEND_DOCKERFILE" 'frontend/pnpm-workspace.yaml'
require_text "$ROOT_DOCKERFILE" 'pnpm@10.28.2'
require_text "$DEPLOY_DOCKERFILE" 'pnpm@10.28.2'
require_text "$FRONTEND_DOCKERFILE" 'pnpm@10.28.2'
require_text "$FRONTEND_DOCKERFILE" 'security-headers.conf /etc/nginx/snippets/aifoo-security-headers.conf'
require_text "$NGINX_CONFIG" 'include /etc/nginx/snippets/aifoo-security-headers.conf;'
require_text "$SECURITY_HEADERS" 'X-Frame-Options "DENY"'
require_text "$SECURITY_HEADERS" 'Content-Security-Policy-Report-Only'
require_text "$VALIDATE_WORKFLOW" 'assert_security_headers'
require_text "$BACKEND_CI_WORKFLOW" 'deploy/tests/install-checksum-test.sh'
require_text "$BACKEND_DEPLOY_WORKFLOW" 'GH_REPO: ${{ github.repository }}'
require_text "$BACKEND_DEPLOY_WORKFLOW" 'git remote set-url official https://github.com/Wei-Shaw/sub2api.git'
reject_trigger "$BACKEND_CI_WORKFLOW" push
reject_trigger "$SECURITY_WORKFLOW" push
require_text "$BACKEND_CI_WORKFLOW" 'uses: ./.github/workflows/macos-shell-ci.yml'
require_text "$MACOS_SHELL_WORKFLOW" 'runs-on: macos-15'
require_text "$MACOS_SHELL_WORKFLOW" 'deploy/tests/apple-container-test.sh'
require_text "$MACOS_SHELL_WORKFLOW" 'deploy/tests/install-github-token-test.sh'

sh -n "$DOCKER_INTEGRATION"
if command -v dash >/dev/null 2>&1; then
  dash -n "$DOCKER_INTEGRATION"
fi
require_text "$DOCKER_INTEGRATION" 'stage_digest "$DIGEST"'
require_text "$DOCKER_INTEGRATION" 'create_backup "$DIGEST"'
require_text "$DOCKER_INTEGRATION" 'deploy_digest "$DIGEST" "$backup_id"'
require_text "$DOCKER_INTEGRATION" 'restore_backup "$DIGEST" "$backup_id"'
require_text "$DOCKER_INTEGRATION" 'LEGACY-AIFOO-MARKER'
require_text "$DOCKER_INTEGRATION" 'HOST-MUTATED-MARKER'
require_text "$DOCKER_INTEGRATION" 'healthcheck:'
require_text "$DOCKER_INTEGRATION" 'disable: true'
require_text "$DOCKER_INTEGRATION" 'INTEGRATION_LABEL=cc.aifoo.integration-run'
require_text "$DOCKER_INTEGRATION" 'mount_count=$(docker inspect'
require_text "$DOCKER_INTEGRATION" 'remove_owned_container "$PRODUCTION_CONTAINER"'
require_text "$DOCKER_INTEGRATION" 'Legacy fixture did not reproduce Compose v1 volume metadata'
require_text "$DOCKER_INTEGRATION" 'Rollback image retained the legacy container volume metadata'
require_text "$DEPLOY_HELPER" '"$rollback_image_id"|missing)'
require_text "$VALIDATE_WORKFLOW" 'timeout-minutes: 30'

require_text "$DEPLOY_HELPER" 'backup)'
require_text "$DEPLOY_HELPER" 'require_backup "$digest" "$backup_id"'
require_text "$DEPLOY_HELPER" 'docker image save --output "$backup_work_dir/frontend-image.tar"'
require_text "$DEPLOY_HELPER" 'docker image tag "$current_image_id" "$snapshot_base_ref"'
reject_text "$DEPLOY_HELPER" 'docker commit "$PRODUCTION_CONTAINER" "$snapshot_base_ref"'
require_text "$DEPLOY_HELPER" "--format '{{json .Config.Volumes}}'"
require_text "$DEPLOY_HELPER" 'Production base image declares volumes and cannot be safely reconstructed'
require_text "$DEPLOY_HELPER" 'Rollback image unexpectedly declares volumes'
require_text "$DEPLOY_HELPER" 'trap restore_failed_deploy EXIT'
require_text "$DEPLOY_HELPER" 'trap - EXIT HUP INT TERM'
require_text "$DEPLOY_HELPER" 'COPY --chown=0:0 nginx/ /etc/nginx/'
require_text "$DEPLOY_HELPER" 'rollback_image_id='
require_text "$DEPLOY_HELPER" 'sha256sum -c SHA256SUMS'
require_text "$DEPLOY_HELPER" 'deploy_digest "${2:-}" "${3:-}"'
require_text "$DEPLOY_HELPER" 'restore_backup "${2:-}" "${3:-}"'
require_text "$DEPLOY_HELPER" 'preload_digest "${2:-}"'
require_text "$DEPLOY_HELPER" 'activate_frontend_digest "${2:-}"'
require_text "$DEPLOY_HELPER" 'preload_service_unchanged=true'
require_text "$DEPLOY_HELPER" 'database_untouched=true'
require_text "$DEPLOY_HELPER" 'restore_activation_compose'
require_text "$DEPLOY_HELPER" 'previous_compose_sha256='
require_text "$DEPLOY_HELPER" 'candidate_compose_sha256='
require_text "$DEPLOY_HELPER" 'rollback_compose_sha256='
require_text "$DEPLOY_HELPER" 'mount-destinations.txt'
require_text "$DEPLOY_HELPER" 'trap restore_interrupted_deploy HUP INT TERM'
require_text "$DEPLOY_HELPER" 'verify_production "$rollback_image_id" legacy'
require_text "$DEPLOY_HELPER" 'wait_for_backend_proxy'

backup_line=$(grep -n 'name: Back up the current frontend' "$DEPLOY_WORKFLOW" | cut -d: -f1)
deploy_line=$(grep -n 'name: Deploy the staged digest after verified backup' "$DEPLOY_WORKFLOW" | cut -d: -f1)
checkout_line=$(grep -n 'name: Checkout approved production revision' "$DEPLOY_WORKFLOW" | cut -d: -f1)
preflight_line=$(grep -n 'name: Require a fresh read-only VPS preflight' "$DEPLOY_WORKFLOW" | cut -d: -f1)
validation_line=$(grep -n 'name: Require successful validation for approved production revision' "$DEPLOY_WORKFLOW" | cut -d: -f1)
reconfirm_line=$(grep -n 'name: Reconfirm approved production revision before deployment' "$DEPLOY_WORKFLOW" | cut -d: -f1)
[ -n "$backup_line" ] || fail "deploy workflow has no backup step"
[ -n "$deploy_line" ] || fail "deploy workflow has no guarded deploy step"
[ -n "$checkout_line" ] || fail "deploy workflow has no checkout step"
[ -n "$preflight_line" ] || fail "deploy workflow has no fresh preflight step"
[ -n "$validation_line" ] || fail "deploy workflow has no current production validation gate"
[ -n "$reconfirm_line" ] || fail "deploy workflow has no final production revision check"
[ "$backup_line" -lt "$deploy_line" ] || fail "backup must run before deployment"
[ "$checkout_line" -lt "$preflight_line" ] || fail "checkout must run before fresh preflight"
[ "$checkout_line" -lt "$validation_line" ] || fail "checkout must run before the validation gate"
[ "$validation_line" -lt "$preflight_line" ] || fail "validation must pass before VPS preflight"
[ "$backup_line" -lt "$reconfirm_line" ] || fail "backup must run before the final production check"
[ "$reconfirm_line" -lt "$deploy_line" ] || fail "production must be rechecked before deployment"
require_text "$DEPLOY_WORKFLOW" 'steps.backup.outputs.backup_id'
require_text "$DEPLOY_WORKFLOW" 'Restore the backup after a failed deployment check'
require_text "$DEPLOY_WORKFLOW" 'deploy-sub2api-frontend restore'
require_text "$DEPLOY_WORKFLOW" 'landing_html=$(curl --fail --location'
require_text "$DEPLOY_WORKFLOW" 'approval:'
require_text "$DEPLOY_WORKFLOW" 'DEPLOY-AIFOO-FRONTEND'
require_text "$DEPLOY_WORKFLOW" 'refs/heads/production'
require_text "$DEPLOY_WORKFLOW" 'Only the repository owner can approve a production deployment'
require_text "$DEPLOY_WORKFLOW" 'statuses: read'
require_text "$DEPLOY_WORKFLOW" 'issues: read'
require_text "$DEPLOY_WORKFLOW" 'uses: actions/checkout@v6'
require_text "$DEPLOY_WORKFLOW" 'Verify validated candidate provenance'
require_text "$DEPLOY_WORKFLOW" 'git merge-base --is-ancestor "$image_source_sha" "$GITHUB_SHA"'
require_text "$DEPLOY_WORKFLOW" 'labels=ready-for-vps'
require_text "$DEPLOY_WORKFLOW" 'Require a fresh read-only VPS preflight'
require_text "$DEPLOY_WORKFLOW" "grep -Fxq 'preflight_result=ready'"
require_text "$DEPLOY_WORKFLOW" "grep -Fxq 'backup_verified=true'"
require_text "$DEPLOY_WORKFLOW" 'aifoo/frontend-validation'
require_text "$DEPLOY_WORKFLOW" 'group: aifoo-production-mutation'
require_text "$DEPLOY_WORKFLOW" 'production_sha=$(git ls-remote origin refs/heads/production'
require_text "$DEPLOY_WORKFLOW" 'if: (failure() || cancelled()) && steps.backup.outputs.backup_id != '\'''\'''

require_text "$PREFLIGHT_WORKFLOW" 'workflow_dispatch:'
require_text "$PREFLIGHT_WORKFLOW" 'permissions:'
require_text "$PREFLIGHT_WORKFLOW" 'contents: read'
require_text "$PREFLIGHT_WORKFLOW" 'Run read-only VPS preflight'
require_text "$PREFLIGHT_WORKFLOW" 'environment:'
require_text "$PREFLIGHT_WORKFLOW" 'name: production'
require_text "$PREFLIGHT_WORKFLOW" 'sudo -n /usr/local/sbin/deploy-sub2api-frontend preflight'
reject_text "$PREFLIGHT_WORKFLOW" 'bash --noprofile --norc -s'
reject_text "$PREFLIGHT_WORKFLOW" '< deploy/frontend/'
reject_text "$PREFLIGHT_WORKFLOW" 'scp '
require_text "$DEPLOY_HELPER" '# BEGIN READ-ONLY PREFLIGHT'
require_text "$DEPLOY_HELPER" '# END READ-ONLY PREFLIGHT'
require_text "$DEPLOY_HELPER" 'preflight_result=blocked'
require_text "$DEPLOY_HELPER" 'preflight_result=ready'
require_text "$DEPLOY_HELPER" 'compose_unchanged='
require_text "$DEPLOY_HELPER" 'containers_unchanged='
require_text "$DEPLOY_HELPER" 'services_unchanged='

preflight_section=$(sed -n \
  '/# BEGIN READ-ONLY PREFLIGHT/,/# END READ-ONLY PREFLIGHT/p' "$DEPLOY_HELPER")
[ -n "$preflight_section" ] || fail 'read-only preflight section is empty'

for forbidden_preflight_command in \
  'docker pull' \
  'docker push' \
  'docker run' \
  'docker exec' \
  'docker cp' \
  'docker login' \
  'docker logout' \
  'docker compose up' \
  'docker-compose up' \
  'systemctl restart' \
  'systemctl reload' \
  'systemctl start' \
  'systemctl stop' \
  'service restart' \
  'mkdir' \
  'install' \
  'touch' \
  'truncate' \
  'chmod' \
  'chown' \
  'rm' \
  'mv' \
  'cp'; do
  if printf '%s\n' "$preflight_section" \
    | grep -Eq -- "(^|[[:space:];|&])${forbidden_preflight_command}([[:space:]]|$)"; then
    fail "read-only preflight contains forbidden command: $forbidden_preflight_command"
  fi
done

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
    healthcheck:
      disable: true
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
MOCK_BASE_VOLUMES=null
MOCK_ROLLBACK_VOLUMES=null
MOCK_FRONTEND_HEALTH_AVAILABLE=false
MOCK_BACKEND_HEALTH_FAILURES_FILE=$TEST_ROOT/backend-health-failures
printf '0\n' > "$MOCK_BACKEND_HEALTH_FAILURES_FILE"
MOCK_SLEEP_CALLS=0
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
      if [ "${5:-}" = "{{json .Config.Volumes}}" ]; then
        case "$target" in
          aifoo-frontend-rollback:*) printf '%s\n' "$MOCK_ROLLBACK_VOLUMES" ;;
          *) printf '%s\n' "$MOCK_BASE_VOLUMES" ;;
        esac
      else
        case "$target" in
          aifoo-frontend-rollback-base:*) printf '%s\n' "$MOCK_CURRENT_IMAGE_ID" ;;
          aifoo-frontend-rollback:*) printf '%s\n' "$MOCK_LOADED_ROLLBACK_ID" ;;
          "$IMAGE_REPOSITORY@$TEST_DIGEST") printf '%s\n' "$REQUESTED_IMAGE_ID" ;;
          *) printf '%s\n' "$target" ;;
        esac
      fi
    else
      echo '[{"Id":"mock"}]'
    fi
    return 0
  fi

  if [ "$1" = "image" ] && [ "$2" = "tag" ]; then
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
    */health)
      remaining_failures=$(cat "$MOCK_BACKEND_HEALTH_FAILURES_FILE")
      if [ "$remaining_failures" -gt 0 ]; then
        printf '%s\n' "$((remaining_failures - 1))" \
          > "$MOCK_BACKEND_HEALTH_FAILURES_FILE"
        return 1
      fi
      echo '{"status":"ok"}'
      ;;
  esac
  return 0
}

sleep() {
  MOCK_SLEEP_CALLS=$((MOCK_SLEEP_CALLS + 1))
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

printf '2\n' > "$MOCK_BACKEND_HEALTH_FAILURES_FILE"
MOCK_SLEEP_CALLS=0
verify_production "$OLD_IMAGE_ID" legacy
[ "$MOCK_SLEEP_CALLS" -eq 2 ] \
  || fail "transient backend proxy startup failures were not retried"

printf '15\n' > "$MOCK_BACKEND_HEALTH_FAILURES_FILE"
MOCK_SLEEP_CALLS=0
if verify_production "$OLD_IMAGE_ID" legacy >/dev/null 2>&1; then
  fail "persistent backend proxy failure passed production verification"
fi
[ "$MOCK_SLEEP_CALLS" -eq 14 ] \
  || fail "backend proxy retry limit was not enforced"
[ "$(cat "$MOCK_BACKEND_HEALTH_FAILURES_FILE")" -eq 0 ] \
  || fail "backend proxy retry limit did not perform all 15 health requests"
printf '0\n' > "$MOCK_BACKEND_HEALTH_FAILURES_FILE"

MOCK_BASE_VOLUMES='{"/usr/share/nginx/html":{}}'
expect_failure "base image volume metadata was accepted" create_backup "$TEST_DIGEST"
MOCK_BASE_VOLUMES=null
MOCK_ROLLBACK_VOLUMES='{"/etc/nginx":{}}'
expect_failure "rollback image volume metadata was accepted" create_backup "$TEST_DIGEST"
MOCK_ROLLBACK_VOLUMES=null

first_output=$(create_backup "$TEST_DIGEST")
first_backup_id=$(printf '%s\n' "$first_output" | sed -n 's/^backup_id=//p' | tail -n 1)
validate_backup_id "$first_backup_id"
first_backup_dir=$BACKUP_ROOT/$first_backup_id
[ -s "$first_backup_dir/frontend-image.tar" ] || fail "backup image archive was not created"
[ -s "$first_backup_dir/nginx/nginx.conf" ] || fail "running Nginx state was not captured"
[ -s "$first_backup_dir/html/index.html" ] || fail "running HTML state was not captured"
[ -s "$first_backup_dir/candidate-compose.yml" ] || fail "candidate Compose was not recorded"
[ -s "$first_backup_dir/rollback-compose.yml" ] || fail "rollback Compose was not recorded"
for rewritten_compose in \
  "$first_backup_dir/candidate-compose.yml" \
  "$first_backup_dir/rollback-compose.yml"; do
  if grep -Eq '^    (volumes|healthcheck):' "$rewritten_compose"; then
    fail "rewritten frontend Compose retained legacy service overrides"
  fi
done
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
if grep -q '^    healthcheck:' "$COMPOSE_FILE"; then
  fail "restore retained the legacy Compose healthcheck override"
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

trigger_unexpected_deploy_exit() {
  (
    active_digest=$TEST_DIGEST
    active_backup_id=$second_backup_id
    rollback_required=true
    trap restore_failed_deploy EXIT
    exit 97
  )
}

cp "$second_backup_dir/docker-compose.yml" "$COMPOSE_FILE"
MOCK_CURRENT_IMAGE_ID=$OLD_IMAGE_ID
write_deployment_state "$TEST_DIGEST" "$second_backup_id"
compose_up_before_previous_exit=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
expect_failure "pre-mutation deployment exit reported success" \
  trigger_unexpected_deploy_exit
compose_up_after_previous_exit=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
[ "$compose_up_after_previous_exit" = "$compose_up_before_previous_exit" ] \
  || fail "pre-mutation deployment exit unnecessarily recreated the frontend"

cp "$second_backup_dir/candidate-compose.yml" "$COMPOSE_FILE"
MOCK_CURRENT_IMAGE_ID=$REQUESTED_IMAGE_ID
compose_up_before_exit=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
expect_failure "unexpected deployment exit reported success" \
  trigger_unexpected_deploy_exit
compose_up_after_exit=$(wc -l < "$TEST_ROOT/compose-up" | tr -d ' ')
[ "$compose_up_after_exit" -gt "$compose_up_before_exit" ] \
  || fail "unexpected deployment exit did not restore the backup"
[ "$(tail -n 1 "$TEST_ROOT/compose-up")" = "rollback" ] \
  || fail "unexpected deployment exit did not finish with rollback"

echo "workflow_contract=ok"
