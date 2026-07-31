#!/bin/sh

set -eu

APP_DIR=/opt/sub2api
COMPOSE_FILE=$APP_DIR/docker-compose.yml
BACKUP_ROOT=/var/backups/sub2api
IMAGE_REPOSITORY=ghcr.io/jayhome137/sub2api-frontend
STAGE_CONTAINER=sub2api-frontend-candidate
STAGE_NETWORK=sub2api_default
STAGE_PORT=18080
STAGE_LABEL_KEY=cc.aifoo.deployment-role
STAGE_LABEL_VALUE=frontend-candidate

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This command must run as root" >&2
    exit 1
  fi
}

validate_digest() {
  if ! printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "Expected sha256:<64 lowercase hex characters>" >&2
    exit 1
  fi
}

cleanup_stage() {
  if ! docker container inspect "$STAGE_CONTAINER" >/dev/null 2>&1; then
    return
  fi

  stage_label=$(docker container inspect "$STAGE_CONTAINER" \
    --format '{{ index .Config.Labels "cc.aifoo.deployment-role" }}')
  if [ "$stage_label" != "$STAGE_LABEL_VALUE" ]; then
    echo "Refusing to remove $STAGE_CONTAINER without the expected deployment label" >&2
    exit 1
  fi

  docker rm -f "$STAGE_CONTAINER" >/dev/null
  echo "staging_container=removed"
}

verify_stage() {
  base_url="http://127.0.0.1:$STAGE_PORT"

  if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$base_url/frontend-health" | grep -q '"status":"ok"'; then
    echo "Staging frontend health check failed" >&2
    return 1
  fi
  if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$base_url/health" | grep -q '"status":"ok"'; then
    echo "Staging backend health check failed" >&2
    return 1
  fi

  if ! landing_html=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$base_url/"); then
    echo "Staging Landing request failed" >&2
    return 1
  fi
  if ! printf '%s' "$landing_html" | grep -q 'AIFoo'; then
    echo "Staging Landing does not contain AIFoo branding" >&2
    return 1
  fi

  for route in login admin/dashboard custom/preflight; do
    if ! app_html=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "$base_url/$route"); then
      echo "Staging route /$route request failed" >&2
      return 1
    fi
    if ! printf '%s' "$app_html" | grep -q '<div id="app"></div>'; then
      echo "Staging route /$route did not return the Vue application" >&2
      return 1
    fi
    if printf '%s' "$app_html" \
      | grep -Eq 'shell-bootstrap|console-override|auth-override|auth-preload|auth-theme-toggle'; then
      echo "Legacy override reference detected on staging route /$route" >&2
      return 1
    fi
  done

  for legacy_asset in \
    shell-bootstrap.js console-override.js console-override.css \
    auth-override.js auth-override.css auth-preload.js auth-theme-toggle.js; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 2 --max-time 5 "$base_url/$legacy_asset")
    if [ "$status" != "404" ]; then
      echo "Expected staging /$legacy_asset to return 404, got $status" >&2
      return 1
    fi
  done
}

stage_digest() {
  digest=$1
  validate_digest "$digest"

  image="$IMAGE_REPOSITORY@$digest"
  docker pull "$image"
  docker image inspect "$image" >/dev/null
  docker network inspect "$STAGE_NETWORK" >/dev/null
  cleanup_stage

  if ! docker run -d \
    --name "$STAGE_CONTAINER" \
    --label "$STAGE_LABEL_KEY=$STAGE_LABEL_VALUE" \
    --label "cc.aifoo.image-digest=$digest" \
    --network "$STAGE_NETWORK" \
    --publish "127.0.0.1:$STAGE_PORT:8080" \
    "$image" >/dev/null; then
    cleanup_stage
    exit 1
  fi

  attempts=0
  status=starting
  while [ "$attempts" -lt 30 ]; do
    status=$(docker inspect "$STAGE_CONTAINER" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      2>/dev/null || true)
    if [ "$status" = "healthy" ]; then
      break
    fi
    if [ "$status" = "unhealthy" ] || [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  if [ "$status" != "healthy" ] || ! verify_stage; then
    docker logs --tail 80 "$STAGE_CONTAINER" >&2 || true
    cleanup_stage
    echo "Staging verification failed" >&2
    exit 1
  fi

  running_image=$(docker inspect "$STAGE_CONTAINER" --format '{{.Image}}')
  expected_image=$(docker image inspect "$image" --format '{{.Id}}')
  if [ "$running_image" != "$expected_image" ]; then
    cleanup_stage
    echo "Staging image ID does not match the requested digest" >&2
    exit 1
  fi

  echo "staged_image=$image"
  echo "staging_health=healthy"
}

require_staged_digest() {
  digest=$1
  image="$IMAGE_REPOSITORY@$digest"

  if ! docker container inspect "$STAGE_CONTAINER" >/dev/null 2>&1; then
    echo "No staging container is available for production deployment" >&2
    exit 1
  fi

  stage_label=$(docker container inspect "$STAGE_CONTAINER" \
    --format '{{ index .Config.Labels "cc.aifoo.deployment-role" }}')
  staged_digest=$(docker container inspect "$STAGE_CONTAINER" \
    --format '{{ index .Config.Labels "cc.aifoo.image-digest" }}')
  stage_status=$(docker container inspect "$STAGE_CONTAINER" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')

  if [ "$stage_label" != "$STAGE_LABEL_VALUE" ] \
    || [ "$staged_digest" != "$digest" ] \
    || [ "$stage_status" != "healthy" ]; then
    echo "Staging container does not match the requested healthy candidate" >&2
    exit 1
  fi

  running_image=$(docker inspect "$STAGE_CONTAINER" --format '{{.Image}}')
  expected_image=$(docker image inspect "$image" --format '{{.Id}}')
  if [ "$running_image" != "$expected_image" ] || ! verify_stage; then
    echo "Staging candidate verification did not pass immediately before deployment" >&2
    exit 1
  fi
}

rewrite_frontend_service() {
  image=$1
  output=$2

  awk -v image="$image" '
    /^  frontend:/ {
      in_frontend = 1
      found_frontend = 1
      print
      next
    }
    in_frontend && /^  [[:alnum:]_-]+:/ {
      in_frontend = 0
      skip_volumes = 0
    }
    in_frontend && /^    image:/ {
      print "    image: " image
      found_image = 1
      next
    }
    in_frontend && /^    volumes:/ {
      skip_volumes = 1
      next
    }
    skip_volumes && /^      - / { next }
    skip_volumes { skip_volumes = 0 }
    { print }
    END {
      if (!found_frontend || !found_image) exit 42
    }
  ' "$COMPOSE_FILE" > "$output"
}

rollback() {
  backup_dir=$1
  echo "Frontend verification failed; restoring the previous compose file" >&2
  cp "$backup_dir/docker-compose.yml" "$COMPOSE_FILE"
  cd "$APP_DIR"
  docker-compose up -d --no-deps --force-recreate frontend
}

deploy_digest() {
  digest=$1
  validate_digest "$digest"

  image="$IMAGE_REPOSITORY@$digest"
  require_staged_digest "$digest"
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  backup_dir="$BACKUP_ROOT/${timestamp}-source-ui-frontend"
  candidate_file=$(mktemp "$APP_DIR/.docker-compose.candidate.XXXXXX")

  docker pull "$image"
  docker image inspect "$image" >/dev/null

  install -d -m 700 "$backup_dir"
  cp "$COMPOSE_FILE" "$backup_dir/docker-compose.yml"
  if [ -d "$APP_DIR/landing" ]; then
    cp -a "$APP_DIR/landing" "$backup_dir/landing"
  fi

  rewrite_frontend_service "$image" "$candidate_file"
  cd "$APP_DIR"
  docker-compose -f "$candidate_file" config -q
  mv "$candidate_file" "$COMPOSE_FILE"

  if ! docker-compose up -d --no-deps --force-recreate frontend; then
    rollback "$backup_dir"
    exit 1
  fi

  attempts=0
  while [ "$attempts" -lt 30 ]; do
    status=$(docker inspect sub2api-frontend --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)
    if [ "$status" = "healthy" ]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  if [ "${status:-}" != "healthy" ] \
    || ! wget -q -T 5 -O /dev/null http://127.0.0.1:8080/frontend-health \
    || ! wget -q -T 5 -O /dev/null http://127.0.0.1:8080/health; then
    docker logs --tail 80 sub2api-frontend >&2 || true
    rollback "$backup_dir"
    exit 1
  fi

  running_image=$(docker inspect sub2api-frontend --format '{{.Image}}')
  expected_image=$(docker image inspect "$image" --format '{{.Id}}')
  if [ "$running_image" != "$expected_image" ]; then
    rollback "$backup_dir"
    echo "Running image ID does not match the requested digest" >&2
    exit 1
  fi

  echo "deployed_image=$image"
  echo "backup_dir=$backup_dir"
  echo "frontend_health=healthy"
}

require_root

command=${1:-}
case "$command" in
  login)
    actor=${2:-}
    case "$actor" in
      ''|*[!A-Za-z0-9_-]*)
        echo "Invalid registry actor" >&2
        exit 1
        ;;
    esac
    docker login ghcr.io --username "$actor" --password-stdin >/dev/null
    ;;
  logout)
    docker logout ghcr.io >/dev/null 2>&1 || true
    ;;
  deploy)
    deploy_digest "${2:-}"
    ;;
  stage)
    stage_digest "${2:-}"
    ;;
  cleanup-stage)
    cleanup_stage
    ;;
  *)
    echo "Usage: $0 {login <actor>|logout|stage <sha256:digest>|deploy <sha256:digest>|cleanup-stage}" >&2
    exit 1
    ;;
esac
