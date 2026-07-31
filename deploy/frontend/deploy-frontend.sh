#!/bin/sh

set -eu

APP_DIR=/opt/sub2api
COMPOSE_FILE=$APP_DIR/docker-compose.yml
BACKUP_ROOT=/var/backups/sub2api
IMAGE_REPOSITORY=ghcr.io/jayhome137/sub2api-frontend

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
  *)
    echo "Usage: $0 {login <actor>|logout|deploy <sha256:digest>}" >&2
    exit 1
    ;;
esac
