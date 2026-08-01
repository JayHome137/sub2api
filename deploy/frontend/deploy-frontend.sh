#!/bin/sh

set -eu

APP_DIR=${AIFOO_APP_DIR:-/opt/sub2api}
COMPOSE_FILE=$APP_DIR/docker-compose.yml
BACKUP_ROOT=${AIFOO_BACKUP_ROOT:-/var/backups/sub2api}
IMAGE_REPOSITORY=${AIFOO_IMAGE_REPOSITORY:-ghcr.io/jayhome137/sub2api-frontend}
PRODUCTION_CONTAINER=${AIFOO_PRODUCTION_CONTAINER:-sub2api-frontend}
PRODUCTION_URL=${AIFOO_PRODUCTION_URL:-http://127.0.0.1:8080}
DEPLOYMENT_STATE_FILE=$APP_DIR/.aifoo-frontend-deployment-state
STAGE_CONTAINER=${AIFOO_STAGE_CONTAINER:-sub2api-frontend-candidate}
STAGE_NETWORK=${AIFOO_STAGE_NETWORK:-sub2api_default}
STAGE_PORT=${AIFOO_STAGE_PORT:-18080}
STAGE_LABEL_KEY=cc.aifoo.deployment-role
STAGE_LABEL_VALUE=frontend-candidate

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This command must run as root" >&2
    exit 1
  fi
}

docker_compose() {
  docker-compose "$@"
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

validate_backup_id() {
  if ! printf '%s' "$1" \
    | grep -Eq '^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{6}-source-ui-frontend$'; then
    echo "Invalid frontend backup ID" >&2
    exit 1
  fi
}

metadata_value() {
  key=$1
  file=$2
  sed -n "s/^$key=//p" "$file"
}

wait_for_ready() {
  container=$1
  mode=$2
  attempts=0
  status=starting
  while [ "$attempts" -lt 30 ]; do
    status=$(docker inspect "$container" \
      --format '{{if .State.Health}}health:{{.State.Health.Status}}{{else}}state:{{.State.Status}}{{end}}' \
      2>/dev/null || true)
    case "$mode:$status" in
      strict:health:healthy|legacy:health:healthy|legacy:state:running)
        return 0
        ;;
      *:health:unhealthy|*:state:exited|*:state:dead)
        return 1
        ;;
    esac
    attempts=$((attempts + 1))
    sleep 2
  done
  return 1
}

verify_production() {
  expected_image_id=$1
  mode=${2:-strict}
  case "$mode" in
    strict|legacy) ;;
    *)
      echo "Invalid production verification mode" >&2
      return 1
      ;;
  esac
  running_image_id=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}')
  if [ "$running_image_id" != "$expected_image_id" ]; then
    echo "Production image ID does not match the expected image" >&2
    return 1
  fi
  if ! wait_for_ready "$PRODUCTION_CONTAINER" "$mode"; then
    echo "Production frontend container is not healthy" >&2
    return 1
  fi
  if [ "$mode" = "strict" ]; then
    if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      "$PRODUCTION_URL/frontend-health" | grep -q '"status":"ok"'; then
      echo "Production frontend health check failed" >&2
      return 1
    fi
  fi
  if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$PRODUCTION_URL/health" | grep -q '"status":"ok"'; then
    echo "Production backend proxy health check failed" >&2
    return 1
  fi
  for route in '' login; do
    if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
      --output /dev/null "$PRODUCTION_URL/$route"; then
      echo "Production route /$route failed" >&2
      return 1
    fi
  done
}

compose_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

deployment_state_matches() {
  digest=$1
  backup_id=$2
  if [ ! -s "$DEPLOYMENT_STATE_FILE" ]; then
    return 1
  fi
  grep -Fxq "backup_id=$backup_id" "$DEPLOYMENT_STATE_FILE" \
    && grep -Fxq "requested_digest=$digest" "$DEPLOYMENT_STATE_FILE"
}

write_deployment_state() {
  digest=$1
  backup_id=$2
  state_file=$(mktemp "$APP_DIR/.aifoo-frontend-deployment-state.XXXXXX") || return 1
  if ! {
    echo "backup_id=$backup_id"
    echo "requested_digest=$digest"
  } > "$state_file"; then
    rm -f -- "$state_file"
    return 1
  fi
  chmod 600 "$state_file" || {
    rm -f -- "$state_file"
    return 1
  }
  mv "$state_file" "$DEPLOYMENT_STATE_FILE" || {
    rm -f -- "$state_file"
    return 1
  }
}

backup_work_dir=
snapshot_base_ref=
rollback_image_ref=

cleanup_backup_workspace() {
  if [ -n "$snapshot_base_ref" ]; then
    docker image rm "$snapshot_base_ref" >/dev/null 2>&1 || true
  fi
  if [ -n "$rollback_image_ref" ]; then
    docker image rm "$rollback_image_ref" >/dev/null 2>&1 || true
  fi
  case "$backup_work_dir" in
    "$BACKUP_ROOT"/.frontend-backup-*)
      if [ -d "$backup_work_dir" ]; then
        rm -rf -- "$backup_work_dir"
      fi
      ;;
  esac
}

abort_backup() {
  trap - EXIT HUP INT TERM
  cleanup_backup_workspace
  exit 130
}

create_backup() {
  digest=$1
  validate_digest "$digest"
  require_staged_digest "$digest"

  if ! docker container inspect "$PRODUCTION_CONTAINER" >/dev/null 2>&1; then
    echo "Production frontend container is unavailable for backup" >&2
    exit 1
  fi

  install -d -m 700 "$BACKUP_ROOT"
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  backup_work_dir=$(mktemp -d "$BACKUP_ROOT/.frontend-backup-${timestamp}.XXXXXX")
  suffix=${backup_work_dir##*.}
  if ! printf '%s' "$suffix" | grep -Eq '^[A-Za-z0-9]{6}$'; then
    echo "Unable to create a unique frontend backup ID" >&2
    exit 1
  fi
  backup_id="${timestamp}-${suffix}-source-ui-frontend"
  backup_dir="$BACKUP_ROOT/$backup_id"
  if [ -e "$backup_dir" ]; then
    echo "Refusing to overwrite existing frontend backup: $backup_id" >&2
    exit 1
  fi

  snapshot_base_ref="aifoo-frontend-rollback-base:${timestamp}-${suffix}"
  rollback_image_ref="aifoo-frontend-rollback:${timestamp}-${suffix}"
  trap cleanup_backup_workspace EXIT
  trap abort_backup HUP INT TERM

  current_image_id=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}')
  current_image_ref=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Config.Image}}')
  current_image_user=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Config.User}}')
  if [ -n "$current_image_user" ] \
    && ! printf '%s' "$current_image_user" | grep -Eq '^[A-Za-z0-9_.:-]+$'; then
    echo "Production image has an unsupported user value" >&2
    exit 1
  fi
  current_compose_sha=$(compose_sha256 "$COMPOSE_FILE")
  requested_image_id=$(docker image inspect "$IMAGE_REPOSITORY@$digest" --format '{{.Id}}')
  verify_production "$current_image_id" legacy

  install -d -m 700 "$backup_work_dir/html"
  install -d -m 700 "$backup_work_dir/nginx"
  cp "$COMPOSE_FILE" "$backup_work_dir/docker-compose.yml"
  if [ -d "$APP_DIR/landing" ]; then
    cp -a "$APP_DIR/landing" "$backup_work_dir/landing"
  fi

  docker container inspect "$PRODUCTION_CONTAINER" > "$backup_work_dir/container-inspect.json"
  docker image inspect "$current_image_id" > "$backup_work_dir/image-inspect.json"
  if ! docker inspect "$PRODUCTION_CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    > "$backup_work_dir/mount-destinations.txt"; then
    echo "Unable to inspect production frontend mounts" >&2
    exit 1
  fi
  unsupported_mounts=$(awk '
    !/^\/etc\/nginx(\/|$)/ && !/^\/usr\/share\/nginx\/html(\/|$)/ { print }
  ' "$backup_work_dir/mount-destinations.txt")
  if [ -n "$unsupported_mounts" ]; then
    echo "Unsupported frontend mount destinations:" >&2
    printf '%s\n' "$unsupported_mounts" >&2
    exit 1
  fi
  docker cp "$PRODUCTION_CONTAINER:/etc/nginx/." "$backup_work_dir/nginx"
  docker cp "$PRODUCTION_CONTAINER:/usr/share/nginx/html/." "$backup_work_dir/html"

  rewrite_frontend_service \
    "$backup_work_dir/docker-compose.yml" \
    "$backup_work_dir/candidate-compose.yml" \
    "$IMAGE_REPOSITORY@$digest"
  docker_compose -f "$backup_work_dir/candidate-compose.yml" config -q
  candidate_compose_sha=$(compose_sha256 "$backup_work_dir/candidate-compose.yml")

  docker commit "$PRODUCTION_CONTAINER" "$snapshot_base_ref" >/dev/null
  {
    echo "FROM $snapshot_base_ref"
    echo "USER 0"
    echo "RUN rm -rf /etc/nginx /usr/share/nginx/html && mkdir -p /etc/nginx /usr/share/nginx/html"
    echo "COPY --chown=0:0 nginx/ /etc/nginx/"
    echo "COPY --chown=0:0 html/ /usr/share/nginx/html/"
    if [ -n "$current_image_user" ]; then
      echo "USER $current_image_user"
    fi
  } > "$backup_work_dir/rollback.Dockerfile"
  docker build \
    --pull=false \
    --no-cache \
    --file "$backup_work_dir/rollback.Dockerfile" \
    --tag "$rollback_image_ref" \
    "$backup_work_dir" >/dev/null

  rollback_image_id=$(docker image inspect "$rollback_image_ref" --format '{{.Id}}')
  if ! printf '%s' "$rollback_image_id" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "Rollback image did not produce a valid image ID" >&2
    exit 1
  fi
  docker image inspect "$rollback_image_ref" > "$backup_work_dir/rollback-image-inspect.json"
  docker image save --output "$backup_work_dir/frontend-image.tar" "$rollback_image_ref"
  rewrite_frontend_service \
    "$backup_work_dir/docker-compose.yml" \
    "$backup_work_dir/rollback-compose.yml" \
    "$rollback_image_ref"
  docker_compose -f "$backup_work_dir/rollback-compose.yml" config -q
  rollback_compose_sha=$(compose_sha256 "$backup_work_dir/rollback-compose.yml")

  {
    echo "backup_id=$backup_id"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "requested_digest=$digest"
    echo "requested_image_id=$requested_image_id"
    echo "previous_image_id=$current_image_id"
    echo "previous_image_ref=$current_image_ref"
    echo "previous_compose_sha256=$current_compose_sha"
    echo "candidate_compose_sha256=$candidate_compose_sha"
    echo "rollback_image_ref=$rollback_image_ref"
    echo "rollback_image_id=$rollback_image_id"
    echo "rollback_compose_sha256=$rollback_compose_sha"
  } > "$backup_work_dir/metadata.env"

  if ! (
    cd "$backup_work_dir"
    # SHA256SUMS is explicitly excluded from the files being hashed.
    # shellcheck disable=SC2094
    find . -type f ! -name SHA256SUMS -exec sha256sum '{}' \; \
      | sort -k 2 > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  ); then
    echo "Frontend backup checksum verification failed" >&2
    exit 1
  fi
  chmod -R go-rwx "$backup_work_dir"
  docker image rm "$snapshot_base_ref" >/dev/null 2>&1 || true
  snapshot_base_ref=
  mv "$backup_work_dir" "$backup_dir"
  backup_work_dir=
  trap - EXIT HUP INT TERM

  echo "backup_id=$backup_id"
  echo "backup_dir=$backup_dir"
  echo "backup_verified=true"
}

require_backup() {
  digest=$1
  backup_id=$2
  mode=${3:-current}
  validate_digest "$digest"
  validate_backup_id "$backup_id"

  backup_dir="$BACKUP_ROOT/$backup_id"
  if [ ! -d "$backup_dir" ] \
    || [ ! -s "$backup_dir/docker-compose.yml" ] \
    || [ ! -s "$backup_dir/frontend-image.tar" ] \
    || [ ! -s "$backup_dir/container-inspect.json" ] \
    || [ ! -s "$backup_dir/rollback-image-inspect.json" ] \
    || [ ! -s "$backup_dir/candidate-compose.yml" ] \
    || [ ! -s "$backup_dir/rollback-compose.yml" ] \
    || [ ! -d "$backup_dir/nginx" ] \
    || [ ! -d "$backup_dir/html" ] \
    || [ ! -s "$backup_dir/metadata.env" ] \
    || [ ! -s "$backup_dir/SHA256SUMS" ]; then
    echo "Frontend backup is incomplete: $backup_id" >&2
    exit 1
  fi

  if ! (
    cd "$backup_dir"
    sha256sum -c SHA256SUMS >/dev/null
  ); then
    echo "Frontend backup checksum verification failed" >&2
    exit 1
  fi

  if ! grep -Fxq "backup_id=$backup_id" "$backup_dir/metadata.env" \
    || ! grep -Fxq "requested_digest=$digest" "$backup_dir/metadata.env"; then
    echo "Frontend backup does not match the requested deployment" >&2
    exit 1
  fi

  previous_image_id=$(metadata_value previous_image_id "$backup_dir/metadata.env")
  requested_image_id=$(metadata_value requested_image_id "$backup_dir/metadata.env")
  rollback_image_id=$(metadata_value rollback_image_id "$backup_dir/metadata.env")
  previous_compose_sha=$(metadata_value previous_compose_sha256 "$backup_dir/metadata.env")
  candidate_compose_sha=$(metadata_value candidate_compose_sha256 "$backup_dir/metadata.env")
  rollback_compose_sha=$(metadata_value rollback_compose_sha256 "$backup_dir/metadata.env")
  current_image_id=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}')
  current_compose_sha=$(compose_sha256 "$COMPOSE_FILE")

  for image_id in "$previous_image_id" "$requested_image_id" "$rollback_image_id"; do
    if ! printf '%s' "$image_id" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
      echo "Frontend backup contains an invalid image ID" >&2
      exit 1
    fi
  done
  for compose_sha in \
    "$previous_compose_sha" "$candidate_compose_sha" "$rollback_compose_sha"; do
    if ! printf '%s' "$compose_sha" | grep -Eq '^[0-9a-f]{64}$'; then
      echo "Frontend backup contains an invalid Compose checksum" >&2
      exit 1
    fi
  done

  case "$mode" in
    current)
      if [ "$current_image_id" != "$previous_image_id" ] \
        || [ "$current_compose_sha" != "$previous_compose_sha" ]; then
        echo "Production frontend changed after this backup was created" >&2
        exit 1
      fi
      ;;
    restore)
      backup_restore_state=
      if [ "$current_image_id" = "$previous_image_id" ] \
        && [ "$current_compose_sha" = "$previous_compose_sha" ]; then
        backup_restore_state=previous
      elif [ "$current_image_id" = "$rollback_image_id" ] \
        && [ "$current_compose_sha" = "$rollback_compose_sha" ]; then
        backup_restore_state=rollback
      elif deployment_state_matches "$digest" "$backup_id"; then
        case "$current_image_id" in
          "$previous_image_id"|"$requested_image_id"|"$rollback_image_id") ;;
          *)
            echo "Refusing to restore against an unrelated frontend image" >&2
            exit 1
            ;;
        esac
        case "$current_compose_sha" in
          "$previous_compose_sha"|"$candidate_compose_sha"|"$rollback_compose_sha") ;;
          *)
            echo "Refusing to restore against an unrelated frontend Compose file" >&2
            exit 1
            ;;
        esac
        backup_restore_state=transition
      else
        echo "Refusing to replay a stale frontend backup against an unrelated image" >&2
        exit 1
      fi
      ;;
    *)
      echo "Invalid backup verification mode" >&2
      exit 1
      ;;
  esac
}

rewrite_frontend_service() {
  source=$1
  output=$2
  image=$3

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
    in_frontend && skip_volumes {
      if (/^      / || /^[[:space:]]*$/) next
      skip_volumes = 0
    }
    { print }
    END {
      if (!found_frontend || !found_image) exit 42
    }
  ' "$source" > "$output"
}

rollback_and_verify() {
  backup_dir=$1
  echo "Restoring the previous frontend image and compose file" >&2
  docker image load --input "$backup_dir/frontend-image.tar" >/dev/null || return 1
  rollback_image_ref=$(metadata_value rollback_image_ref "$backup_dir/metadata.env") \
    || return 1
  rollback_image_id=$(metadata_value rollback_image_id "$backup_dir/metadata.env") \
    || return 1
  if ! printf '%s' "$rollback_image_ref" \
    | grep -Eq '^aifoo-frontend-rollback:[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{6}$' \
    || ! printf '%s' "$rollback_image_id" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "Backup does not contain a valid rollback image reference" >&2
    return 1
  fi
  loaded_image_id=$(docker image inspect "$rollback_image_ref" --format '{{.Id}}') \
    || return 1
  if [ "$loaded_image_id" != "$rollback_image_id" ]; then
    echo "Loaded rollback image ID does not match the verified backup" >&2
    return 1
  fi
  restore_file=$(mktemp "$APP_DIR/.docker-compose.restore.XXXXXX") || return 1
  if ! cp "$backup_dir/rollback-compose.yml" "$restore_file"; then
    rm -f -- "$restore_file"
    return 1
  fi
  if ! docker_compose -f "$restore_file" config -q; then
    rm -f -- "$restore_file"
    return 1
  fi
  if ! mv "$restore_file" "$COMPOSE_FILE"; then
    rm -f -- "$restore_file"
    return 1
  fi
  cd "$APP_DIR" || return 1
  docker_compose up -d --no-deps --force-recreate frontend || return 1
  if ! verify_production "$rollback_image_id" legacy; then
    docker logs --tail 80 "$PRODUCTION_CONTAINER" >&2 || true
    echo "Frontend rollback verification failed" >&2
    return 1
  fi

  echo "rollback_image_id=$rollback_image_id"
  echo "rollback_health=healthy"
}

restore_backup() {
  digest=$1
  backup_id=$2
  require_backup "$digest" "$backup_id" restore
  backup_dir="$BACKUP_ROOT/$backup_id"
  case "$backup_restore_state" in
    previous)
      previous_image_id=$(metadata_value previous_image_id "$backup_dir/metadata.env")
      verify_production "$previous_image_id" legacy
      echo "restored_backup_id=$backup_id"
      echo "restore_state=already_previous"
      return 0
      ;;
    rollback)
      rollback_image_id=$(metadata_value rollback_image_id "$backup_dir/metadata.env")
      verify_production "$rollback_image_id" legacy
      echo "restored_backup_id=$backup_id"
      echo "restore_state=already_rollback"
      return 0
      ;;
  esac
  rollback_and_verify "$backup_dir"

  echo "restored_backup_id=$backup_id"
}

rollback_required=false
active_backup_dir=

restore_interrupted_deploy() {
  trap - HUP INT TERM
  if [ "$rollback_required" = "true" ] && [ -n "$active_backup_dir" ]; then
    echo "Deployment interrupted; restoring the verified frontend backup" >&2
    if ! rollback_and_verify "$active_backup_dir"; then
      echo "Automatic restore failed; manual intervention is required" >&2
    fi
  fi
  exit 130
}

fail_deploy_and_restore() {
  trap - HUP INT TERM
  if ! rollback_and_verify "$active_backup_dir"; then
    echo "Automatic restore failed; manual intervention is required" >&2
  fi
  exit 1
}

deploy_digest() {
  digest=$1
  backup_id=$2
  validate_digest "$digest"
  validate_backup_id "$backup_id"

  image="$IMAGE_REPOSITORY@$digest"
  require_staged_digest "$digest"
  require_backup "$digest" "$backup_id"
  backup_dir="$BACKUP_ROOT/$backup_id"
  candidate_file=$(mktemp "$APP_DIR/.docker-compose.candidate.XXXXXX")

  docker pull "$image"
  docker image inspect "$image" >/dev/null

  rewrite_frontend_service "$COMPOSE_FILE" "$candidate_file" "$image"
  cd "$APP_DIR"
  docker_compose -f "$candidate_file" config -q
  write_deployment_state "$digest" "$backup_id"
  active_backup_dir=$backup_dir
  rollback_required=true
  trap restore_interrupted_deploy HUP INT TERM
  mv "$candidate_file" "$COMPOSE_FILE"

  if ! docker_compose up -d --no-deps --force-recreate frontend; then
    fail_deploy_and_restore
  fi

  expected_image=$(docker image inspect "$image" --format '{{.Id}}')
  if ! verify_production "$expected_image" strict; then
    docker logs --tail 80 "$PRODUCTION_CONTAINER" >&2 || true
    fail_deploy_and_restore
  fi

  rollback_required=false
  active_backup_dir=
  trap - HUP INT TERM

  echo "deployed_image=$image"
  echo "backup_dir=$backup_dir"
  echo "frontend_health=healthy"
}

if [ "${AIFOO_DEPLOY_LIBRARY_ONLY:-0}" != "1" ]; then
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
    deploy_digest "${2:-}" "${3:-}"
    ;;
  backup)
    create_backup "${2:-}"
    ;;
  restore)
    restore_backup "${2:-}" "${3:-}"
    ;;
  stage)
    stage_digest "${2:-}"
    ;;
  cleanup-stage)
    cleanup_stage
    ;;
    *)
      echo "Usage: $0 {login <actor>|logout|stage <sha256:digest>|backup <sha256:digest>|deploy <sha256:digest> <backup-id>|restore <sha256:digest> <backup-id>|cleanup-stage}" >&2
      exit 1
      ;;
  esac
fi
