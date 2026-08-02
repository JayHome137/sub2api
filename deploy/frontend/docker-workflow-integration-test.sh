#!/bin/sh

# shellcheck disable=SC1090

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
DEPLOY_HELPER=$ROOT/deploy/frontend/deploy-frontend.sh
TEMP_BASE=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
TEST_ROOT=$(mktemp -d "$TEMP_BASE/aifoo-docker-integration.XXXXXX")
SUFFIX=${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-1}
COMPOSE_PROJECT=aifoo-integration-$SUFFIX
NETWORK=aifoo-integration-$SUFFIX
REGISTRY_CONTAINER=aifoo-integration-registry-$SUFFIX
BACKEND_CONTAINER=aifoo-integration-backend-$SUFFIX
PRODUCTION_CONTAINER=aifoo-integration-frontend-$SUFFIX
STAGE_CONTAINER=aifoo-integration-stage-$SUFFIX
REGISTRY_PORT=15000
PRODUCTION_PORT=18082
STAGE_PORT=18081
LOCAL_REPOSITORY=localhost:$REGISTRY_PORT/aifoo/sub2api-frontend
LOCAL_TAG=$LOCAL_REPOSITORY:integration
INTEGRATION_LABEL=cc.aifoo.integration-run
INTEGRATION_OWNER=$SUFFIX
DIGEST=
TEST_ROLLBACK_IMAGE_REF=

remove_owned_container() {
  container=$1
  if ! docker container inspect "$container" >/dev/null 2>&1; then
    return
  fi
  owner=$(docker container inspect "$container" \
    --format "{{ index .Config.Labels \"$INTEGRATION_LABEL\" }}" 2>/dev/null) \
    || owner=
  if [ "$owner" = "$INTEGRATION_OWNER" ]; then
    docker rm -fv "$container" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if command -v cleanup_stage >/dev/null 2>&1; then
    cleanup_stage >/dev/null 2>&1 || true
  fi
  remove_owned_container "$PRODUCTION_CONTAINER"
  remove_owned_container "$BACKEND_CONTAINER"
  remove_owned_container "$REGISTRY_CONTAINER"
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    owner=$(docker network inspect "$NETWORK" \
      --format "{{ index .Labels \"$INTEGRATION_LABEL\" }}" 2>/dev/null) \
      || owner=
    if [ "$owner" = "$INTEGRATION_OWNER" ]; then
      docker network rm "$NETWORK" >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$TEST_ROLLBACK_IMAGE_REF" ]; then
    docker image rm "$TEST_ROLLBACK_IMAGE_REF" >/dev/null 2>&1 || true
  fi
  if [ -n "$DIGEST" ]; then
    docker image rm "$LOCAL_REPOSITORY@$DIGEST" >/dev/null 2>&1 || true
  fi
  docker image rm "$LOCAL_TAG" >/dev/null 2>&1 || true
  case "$TEST_ROOT" in
    "$TEMP_BASE"/aifoo-docker-integration.*)
      rm -rf -- "$TEST_ROOT"
      ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

CANDIDATE_IMAGE=${AIFOO_CANDIDATE_IMAGE:-}
if [ -z "$CANDIDATE_IMAGE" ]; then
  echo "AIFOO_CANDIDATE_IMAGE is required" >&2
  exit 1
fi
docker image inspect "$CANDIDATE_IMAGE" >/dev/null

install -d "$TEST_ROOT/app/legacy-html" "$TEST_ROOT/backups"
cat > "$TEST_ROOT/app/legacy-html/index.html" <<'EOF'
<!doctype html>
<html><body>LEGACY-AIFOO-MARKER</body></html>
EOF
cat > "$TEST_ROOT/app/legacy-default.conf" <<'EOF'
server {
  listen 8080 default_server;
  server_name _;
  root /usr/share/nginx/html;

  location = /health {
    proxy_pass http://sub2api:8080/health;
  }

  location / {
    try_files $uri /index.html;
  }
}
EOF
cat > "$TEST_ROOT/app/docker-compose.yml" <<EOF
services:
  frontend:
    image: nginx:1.27-alpine
    container_name: $PRODUCTION_CONTAINER
    networks:
      - integration
    ports:
      - "127.0.0.1:$PRODUCTION_PORT:8080"
    healthcheck:
      disable: true
    labels:
      $INTEGRATION_LABEL: $INTEGRATION_OWNER
    volumes:
      - ./legacy-default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./legacy-html:/usr/share/nginx/html:ro

networks:
  integration:
    external: true
    name: $NETWORK
EOF

docker network create \
  --label "$INTEGRATION_LABEL=$INTEGRATION_OWNER" \
  "$NETWORK" >/dev/null
docker run -d \
  --name "$REGISTRY_CONTAINER" \
  --label "$INTEGRATION_LABEL=$INTEGRATION_OWNER" \
  --publish "127.0.0.1:$REGISTRY_PORT:5000" \
  registry:2 >/dev/null
docker run -d \
  --name "$BACKEND_CONTAINER" \
  --label "$INTEGRATION_LABEL=$INTEGRATION_OWNER" \
  --network "$NETWORK" \
  --network-alias sub2api \
  busybox:1.36 \
  sh -c 'mkdir -p /www && printf "{\"status\":\"ok\"}\n" > /www/health && httpd -f -p 8080 -h /www' \
  >/dev/null

registry_ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent --output /dev/null \
    --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$REGISTRY_PORT/v2/"; then
    registry_ready=true
    break
  fi
  sleep 1
done
if [ "$registry_ready" != "true" ]; then
  echo "Temporary registry did not become ready" >&2
  exit 1
fi

docker tag "$CANDIDATE_IMAGE" "$LOCAL_TAG"
push_output=$(docker push "$LOCAL_TAG" 2>&1)
printf '%s\n' "$push_output"
DIGEST=$(printf '%s\n' "$push_output" \
  | sed -n 's/.*digest: \(sha256:[0-9a-f]\{64\}\).*/\1/p' \
  | tail -n 1)
if ! printf '%s' "$DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
  echo "Unable to resolve the temporary registry digest" >&2
  exit 1
fi

docker compose \
  --project-name "$COMPOSE_PROJECT" \
  --file "$TEST_ROOT/app/docker-compose.yml" \
  up -d >/dev/null

legacy_ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$PRODUCTION_PORT/health" | grep -q '"status":"ok"' \
    && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "http://127.0.0.1:$PRODUCTION_PORT/" | grep -q LEGACY-AIFOO-MARKER; then
    legacy_ready=true
    break
  fi
  sleep 1
done
if [ "$legacy_ready" != "true" ]; then
  echo "Legacy frontend fixture did not become ready" >&2
  exit 1
fi
legacy_state=$(docker inspect "$PRODUCTION_CONTAINER" \
  --format '{{if .State.Health}}health:{{.State.Health.Status}}{{else}}state:{{.State.Status}}{{end}}')
if [ "$legacy_state" != "state:running" ]; then
  echo "Legacy fixture must be running without Docker health state" >&2
  exit 1
fi
if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/frontend-health" \
  | grep -q '"status":"ok"'; then
  echo "Legacy fixture unexpectedly exposes the candidate frontend health endpoint" >&2
  exit 1
fi

AIFOO_DEPLOY_LIBRARY_ONLY=1
AIFOO_APP_DIR=$TEST_ROOT/app
AIFOO_BACKUP_ROOT=$TEST_ROOT/backups
AIFOO_IMAGE_REPOSITORY=$LOCAL_REPOSITORY
AIFOO_PRODUCTION_CONTAINER=$PRODUCTION_CONTAINER
AIFOO_PRODUCTION_URL=http://127.0.0.1:$PRODUCTION_PORT
AIFOO_STAGE_CONTAINER=$STAGE_CONTAINER
AIFOO_STAGE_NETWORK=$NETWORK
AIFOO_STAGE_PORT=$STAGE_PORT
export \
  AIFOO_DEPLOY_LIBRARY_ONLY \
  AIFOO_APP_DIR \
  AIFOO_BACKUP_ROOT \
  AIFOO_IMAGE_REPOSITORY \
  AIFOO_PRODUCTION_CONTAINER \
  AIFOO_PRODUCTION_URL \
  AIFOO_STAGE_CONTAINER \
  AIFOO_STAGE_NETWORK \
  AIFOO_STAGE_PORT
. "$DEPLOY_HELPER"

docker_compose() {
  docker compose --project-name "$COMPOSE_PROJECT" "$@"
}

stage_digest "$DIGEST"
backup_output=$(create_backup "$DIGEST")
printf '%s\n' "$backup_output"
backup_id=$(printf '%s\n' "$backup_output" \
  | sed -n 's/^backup_id=//p' \
  | tail -n 1)
validate_backup_id "$backup_id"
TEST_ROLLBACK_IMAGE_REF=$(metadata_value rollback_image_ref \
  "$AIFOO_BACKUP_ROOT/$backup_id/metadata.env")

# Break the original bind sources after backup so deploy and restore can only
# pass when their Compose files use the candidate and rollback image contents.
cat > "$TEST_ROOT/app/legacy-html/index.html" <<'EOF'
<!doctype html>
<html><body>HOST-MUTATED-MARKER</body></html>
EOF
cat > "$TEST_ROOT/app/legacy-default.conf" <<'EOF'
server {
  listen 8080 default_server;
  server_name _;
  location / { return 503; }
}
EOF
curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/" | grep -q HOST-MUTATED-MARKER

deploy_digest "$DIGEST" "$backup_id"
trap 'exit 130' HUP INT TERM
curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/frontend-health" | grep -q '"status":"ok"'
curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/" | grep -q AIFoo

# Exercise disaster recovery when the candidate container no longer exists.
remove_owned_container "$PRODUCTION_CONTAINER"
if docker container inspect "$PRODUCTION_CONTAINER" >/dev/null 2>&1; then
  echo "Candidate frontend container was not removed before restore" >&2
  exit 1
fi

restore_backup "$DIGEST" "$backup_id"
curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/health" | grep -q '"status":"ok"'
restored_html=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  "http://127.0.0.1:$PRODUCTION_PORT/")
printf '%s' "$restored_html" | grep -q LEGACY-AIFOO-MARKER
if printf '%s' "$restored_html" | grep -q HOST-MUTATED-MARKER; then
  echo "Restore still depends on the mutated legacy bind source" >&2
  exit 1
fi
mount_count=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{len .Mounts}}')
if [ "$mount_count" != "0" ]; then
  echo "Restored frontend unexpectedly retains legacy bind mounts" >&2
  exit 1
fi

cleanup_stage
echo "docker_workflow_integration=ok"
