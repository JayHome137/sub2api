#!/bin/sh

set -eu

APP_DIR=${AIFOO_APP_DIR:-/opt/sub2api}
COMPOSE_FILE=$APP_DIR/docker-compose.yml
BACKUP_ROOT=${AIFOO_BACKUP_ROOT:-/var/backups/sub2api}
IMAGE_REPOSITORY=${AIFOO_IMAGE_REPOSITORY:-ghcr.io/jayhome137/sub2api-frontend}
PRODUCTION_CONTAINER=${AIFOO_PRODUCTION_CONTAINER:-sub2api-frontend}
PRODUCTION_URL=${AIFOO_PRODUCTION_URL:-http://127.0.0.1:8080}
DEPLOYMENT_STATE_FILE=$APP_DIR/.aifoo-frontend-deployment-state
PRELOAD_STATE_FILE=$APP_DIR/.aifoo-frontend-preload-state
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

# BEGIN READ-ONLY PREFLIGHT
preflight_block() {
  preflight_blocker_count=$((preflight_blocker_count + 1))
  printf 'blocker=%s\n' "$1"
}

preflight_warn() {
  preflight_warning_count=$((preflight_warning_count + 1))
  printf 'warning=%s\n' "$1"
}

preflight_file_hash() {
  if [ -r "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'missing\n'
  fi
}

preflight_container_fingerprint() {
  if ! command -v docker >/dev/null 2>&1; then
    printf 'docker-missing\n'
    return
  fi

  for container_id in $(docker ps -aq 2>/dev/null); do
    docker inspect "$container_id" \
      --format '{{.Id}}|{{.State.Status}}|{{.RestartCount}}|{{.Config.Image}}|{{.State.StartedAt}}' \
      2>/dev/null
  done | sort | sha256sum | awk '{print $1}'
}

preflight_service_fingerprint() {
  for unit_name in docker nginx containerd; do
    printf '%s|' "$unit_name"
    systemctl show "$unit_name" \
      --property=ActiveState \
      --property=SubState \
      --value 2>/dev/null | tr '\n' ':' || true
    printf '\n'
  done | sha256sum | awk '{print $1}'
}

preflight_readonly() {
  set +e

  expected_helper_sha=${1:-}
  preflight_blocker_count=0
  preflight_warning_count=0
  min_available_memory_mb=${AIFOO_MIN_AVAILABLE_MEMORY_MB:-512}
  min_available_disk_kb=${AIFOO_MIN_AVAILABLE_DISK_KB:-2097152}

  compose_hash_before=$(preflight_file_hash "$COMPOSE_FILE")
  helper_hash_before=$(preflight_file_hash "$0")
  containers_before=$(preflight_container_fingerprint)
  services_before=$(preflight_service_fingerprint)

  printf 'preflight_time_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'preflight_user=%s uid=%s\n' "$(id -un)" "$(id -u)"

  if ! printf '%s' "$expected_helper_sha" | grep -Eq '^[0-9a-f]{64}$'; then
    preflight_block expected_helper_sha_missing_or_invalid
  elif [ "$helper_hash_before" != "$expected_helper_sha" ]; then
    preflight_block deploy_helper_sha_mismatch
  fi

  helper_owner=$(stat -c '%U' "$0" 2>/dev/null || true)
  helper_mode=$(stat -c '%a' "$0" 2>/dev/null || true)
  printf 'deploy_helper_owner=%s mode=%s sha256=%s\n' \
    "$helper_owner" "$helper_mode" "$helper_hash_before"
  if [ "$helper_owner" != "root" ]; then
    preflight_block deploy_helper_not_owned_by_root
  fi
  if find "$0" -perm /022 -print -quit 2>/dev/null | grep -q .; then
    preflight_block deploy_helper_group_or_world_writable
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'os=%s\n' "${PRETTY_NAME:-unknown}"
  fi
  printf 'kernel=%s architecture=%s cpu_count=%s\n' \
    "$(uname -r)" \
    "$(uname -m)" \
    "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)"
  printf 'load_average=%s\n' "$(cat /proc/loadavg)"

  available_memory_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
  printf 'available_memory_mb=%s\n' "$available_memory_mb"
  if [ -z "$available_memory_mb" ] \
    || [ "$available_memory_mb" -lt "$min_available_memory_mb" ]; then
    preflight_block insufficient_available_memory
  fi

  if [ -e "$APP_DIR" ]; then
    available_disk_kb=$(df -Pk "$APP_DIR" | awk 'NR == 2 {print $4}')
  else
    available_disk_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
  fi
  printf 'available_disk_kb=%s\n' "$available_disk_kb"
  if [ -z "$available_disk_kb" ] \
    || [ "$available_disk_kb" -lt "$min_available_disk_kb" ]; then
    preflight_block insufficient_available_disk
  fi

  for unit_name in docker nginx containerd; do
    unit_state=$(systemctl is-active "$unit_name" 2>/dev/null || true)
    printf 'service[%s]=%s\n' "$unit_name" "$unit_state"
    if [ "$unit_state" != "active" ]; then
      preflight_block "service_${unit_name}_not_active"
    fi
  done

  if ! command -v docker >/dev/null 2>&1; then
    preflight_block docker_missing
  else
    docker_client=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
    docker_server=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
    printf 'docker_client=%s docker_server=%s\n' "$docker_client" "$docker_server"
    if [ -z "$docker_client" ] || [ -z "$docker_server" ]; then
      preflight_block docker_unavailable
    fi
  fi

  compose_command=missing
  if command -v docker-compose >/dev/null 2>&1 \
    && docker-compose version >/dev/null 2>&1; then
    compose_command=v1
    compose_version=$(docker-compose version --short 2>/dev/null || true)
  else
    compose_version=
    preflight_block docker_compose_missing
  fi
  printf 'compose_command=%s compose_version=%s\n' "$compose_command" "$compose_version"

  if [ ! -r "$COMPOSE_FILE" ]; then
    preflight_block compose_missing_or_unreadable
  else
    compose_owner=$(stat -c '%U' "$COMPOSE_FILE" 2>/dev/null || true)
    compose_mode=$(stat -c '%a' "$COMPOSE_FILE" 2>/dev/null || true)
    printf 'compose_owner=%s compose_mode=%s compose_sha256=%s\n' \
      "$compose_owner" "$compose_mode" "$compose_hash_before"
    if [ "$compose_owner" != "root" ]; then
      preflight_block compose_not_owned_by_root
    fi
    if find "$COMPOSE_FILE" -perm /022 -print -quit 2>/dev/null | grep -q .; then
      preflight_block compose_group_or_world_writable
    fi

    if [ "$compose_command" = "v1" ]; then
      compose_services=$(docker-compose -f "$COMPOSE_FILE" config --services 2>/dev/null | sort)
    else
      compose_services=
    fi
    printf 'compose_services=%s\n' "$(printf '%s\n' "$compose_services" | paste -sd, -)"
    for required_service in frontend postgres redis sub2api; do
      if ! printf '%s\n' "$compose_services" | grep -Fxq "$required_service"; then
        preflight_block "compose_service_${required_service}_missing"
      fi
    done
  fi

  if ! docker network inspect "$STAGE_NETWORK" >/dev/null 2>&1; then
    preflight_block staging_network_missing
  else
    printf 'staging_network=%s\n' "$STAGE_NETWORK"
  fi

  if ! command -v ss >/dev/null 2>&1; then
    preflight_block socket_inspection_tool_missing
  elif ss -lntH 2>/dev/null \
    | awk '{print $4}' \
    | awk -F: -v port="$STAGE_PORT" '$NF == port {found=1} END {exit !found}'; then
    preflight_block staging_port_occupied
  else
    printf 'staging_port_%s=free\n' "$STAGE_PORT"
  fi

  for required_container in sub2api sub2api-postgres sub2api-redis "$PRODUCTION_CONTAINER"; do
    if ! docker container inspect "$required_container" >/dev/null 2>&1; then
      preflight_block "container_${required_container}_missing"
      continue
    fi

    container_state=$(docker inspect "$required_container" --format '{{.State.Status}}')
    container_health=$(docker inspect "$required_container" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
    container_restarts=$(docker inspect "$required_container" --format '{{.RestartCount}}')
    printf 'container[%s]_state=%s health=%s restarts=%s\n' \
      "$required_container" "$container_state" "$container_health" "$container_restarts"
    if [ "$container_state" != "running" ]; then
      preflight_block "container_${required_container}_not_running"
    fi
    if [ "$required_container" = "$PRODUCTION_CONTAINER" ]; then
      if [ "$container_health" = "unhealthy" ]; then
        preflight_block frontend_container_unhealthy
      fi
    elif [ "$container_health" != "healthy" ]; then
      preflight_block "container_${required_container}_not_healthy"
    fi
  done

  if docker container inspect "$PRODUCTION_CONTAINER" >/dev/null 2>&1; then
    frontend_image_ref=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Config.Image}}')
    frontend_ports=$(docker port "$PRODUCTION_CONTAINER" 2>/dev/null)
    printf 'frontend_image_ref=%s\n' "$frontend_image_ref"
    printf 'frontend_ports=%s\n' "$(printf '%s\n' "$frontend_ports" | paste -sd, -)"
    if ! printf '%s\n' "$frontend_ports" | grep -Eq '127\.0\.0\.1:8080$'; then
      preflight_block frontend_loopback_port_mapping_missing
    fi

    mount_destinations=$(docker inspect "$PRODUCTION_CONTAINER" \
      --format '{{range .Mounts}}{{println .Destination}}{{end}}')
    printf 'frontend_mount_destinations=%s\n' \
      "$(printf '%s\n' "$mount_destinations" | sed '/^$/d' | sort | paste -sd, -)"
    unsupported_mounts=$(printf '%s\n' "$mount_destinations" | awk '
      NF && !/^\/etc\/nginx(\/|$)/ && !/^\/usr\/share\/nginx\/html(\/|$)/ { print }
    ')
    if [ -n "$unsupported_mounts" ]; then
      preflight_block unsupported_frontend_mounts
      printf 'unsupported_mount_destinations=%s\n' \
        "$(printf '%s\n' "$unsupported_mounts" | paste -sd, -)"
    else
      printf 'frontend_mounts_compatible=true\n'
    fi
  fi

  if [ -e "$BACKUP_ROOT" ]; then
    backup_owner=$(stat -c '%U' "$BACKUP_ROOT" 2>/dev/null || true)
    backup_mode=$(stat -c '%a' "$BACKUP_ROOT" 2>/dev/null || true)
    printf 'backup_root=present owner=%s mode=%s\n' "$backup_owner" "$backup_mode"
    if [ "$backup_owner" != "root" ]; then
      preflight_block backup_root_not_owned_by_root
    fi
    if [ "$backup_mode" != "700" ]; then
      preflight_warn backup_root_requires_hardening_before_deployment
    fi
  else
    printf 'backup_root=absent\n'
    preflight_warn backup_root_requires_authorized_creation
  fi

  compose_hash_after=$(preflight_file_hash "$COMPOSE_FILE")
  helper_hash_after=$(preflight_file_hash "$0")
  containers_after=$(preflight_container_fingerprint)
  services_after=$(preflight_service_fingerprint)

  if [ "$compose_hash_before" != "$compose_hash_after" ]; then
    preflight_block compose_changed_during_preflight
  fi
  if [ "$helper_hash_before" != "$helper_hash_after" ]; then
    preflight_block deploy_helper_changed_during_preflight
  fi
  if [ "$containers_before" != "$containers_after" ]; then
    preflight_block container_state_changed_during_preflight
  fi
  if [ "$services_before" != "$services_after" ]; then
    preflight_block service_state_changed_during_preflight
  fi

  printf 'compose_unchanged=%s\n' "$([ "$compose_hash_before" = "$compose_hash_after" ] && printf true || printf false)"
  printf 'helper_unchanged=%s\n' "$([ "$helper_hash_before" = "$helper_hash_after" ] && printf true || printf false)"
  printf 'containers_unchanged=%s\n' "$([ "$containers_before" = "$containers_after" ] && printf true || printf false)"
  printf 'services_unchanged=%s\n' "$([ "$services_before" = "$services_after" ] && printf true || printf false)"
  printf 'warning_count=%s blocker_count=%s\n' \
    "$preflight_warning_count" "$preflight_blocker_count"

  if [ "$preflight_blocker_count" -ne 0 ]; then
    printf 'preflight_result=blocked\n'
    return 1
  fi

  printf 'preflight_result=ready\n'
}
# END READ-ONLY PREFLIGHT

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

write_preload_state() {
  digest=$1
  image_id=$2
  state_file=$(mktemp "$APP_DIR/.aifoo-frontend-preload-state.XXXXXX") || return 1
  if ! {
    echo "requested_digest=$digest"
    echo "image_id=$image_id"
    echo "preloaded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$state_file"; then
    rm -f -- "$state_file"
    return 1
  fi
  chmod 600 "$state_file" || {
    rm -f -- "$state_file"
    return 1
  }
  mv "$state_file" "$PRELOAD_STATE_FILE" || {
    rm -f -- "$state_file"
    return 1
  }
}

preload_digest() {
  digest=$1
  validate_digest "$digest"

  image="$IMAGE_REPOSITORY@$digest"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull "$image" >/dev/null
  fi
  image_id=$(docker image inspect "$image" --format '{{.Id}}')
  repo_digests=$(docker image inspect "$image" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}')
  if ! printf '%s\n' "$repo_digests" | grep -Fxq "$image"; then
    echo "Preloaded image does not retain the requested immutable digest" >&2
    exit 1
  fi
  write_preload_state "$digest" "$image_id"
  echo "preloaded_image=$image"
  echo "preloaded_image_id=$image_id"
  echo "preload_service_unchanged=true"
}

require_preloaded_digest() {
  digest=$1
  image="$IMAGE_REPOSITORY@$digest"
  if [ ! -s "$PRELOAD_STATE_FILE" ] \
    || ! grep -Fxq "requested_digest=$digest" "$PRELOAD_STATE_FILE"; then
    echo "The requested frontend digest is not preloaded on the VPS" >&2
    exit 1
  fi
  image_id=$(docker image inspect "$image" --format '{{.Id}}')
  recorded_image_id=$(sed -n 's/^image_id=//p' "$PRELOAD_STATE_FILE")
  if [ -z "$recorded_image_id" ] || [ "$recorded_image_id" != "$image_id" ]; then
    echo "The preloaded frontend image no longer matches its recorded image ID" >&2
    exit 1
  fi
  repo_digests=$(docker image inspect "$image" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}')
  if ! printf '%s\n' "$repo_digests" | grep -Fxq "$image"; then
    echo "The preloaded frontend image no longer matches its requested digest" >&2
    exit 1
  fi
}

verify_frontend_activation() {
  expected_image_id=$1
  running_image_id=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}')
  if [ "$running_image_id" != "$expected_image_id" ]; then
    echo "Activated frontend image ID does not match the preloaded image" >&2
    return 1
  fi
  if ! wait_for_ready "$PRODUCTION_CONTAINER" strict; then
    echo "Activated frontend container is not healthy" >&2
    return 1
  fi
  if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$PRODUCTION_URL/frontend-health" | grep -q '"status":"ok"'; then
    echo "Activated frontend health check failed" >&2
    return 1
  fi
}

restore_activation_compose() {
  old_compose_file=$1
  if ! cp "$old_compose_file" "$COMPOSE_FILE"; then
    echo "Unable to restore the previous frontend Compose file" >&2
    return 1
  fi
  if ! docker_compose up -d --no-deps --force-recreate frontend; then
    echo "Unable to restart the previous frontend after activation failure" >&2
    return 1
  fi
  if ! wait_for_ready "$PRODUCTION_CONTAINER" legacy; then
    echo "Previous frontend did not return to a running state" >&2
    return 1
  fi
}

activate_frontend_digest() {
  digest=$1
  validate_digest "$digest"
  require_preloaded_digest "$digest"

  image="$IMAGE_REPOSITORY@$digest"
  expected_image_id=$(docker image inspect "$image" --format '{{.Id}}')
  old_compose_file=$(mktemp "$APP_DIR/.docker-compose.activate-old.XXXXXX")
  candidate_file=$(mktemp "$APP_DIR/.docker-compose.activate-candidate.XXXXXX")
  if ! cp "$COMPOSE_FILE" "$old_compose_file"; then
    rm -f -- "$old_compose_file" "$candidate_file"
    echo "Unable to snapshot the active frontend Compose file" >&2
    exit 1
  fi

  cleanup_activation() {
    rm -f -- "$old_compose_file" "$candidate_file"
  }

  if grep -Fq "image: $image" "$COMPOSE_FILE" \
    && docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}' 2>/dev/null \
      | grep -Fxq "$expected_image_id"; then
    cleanup_activation
    rm -f -- "$PRELOAD_STATE_FILE"
    echo "already_active=true"
    echo "activated_image=$image"
    return 0
  fi

  if ! rewrite_frontend_service "$COMPOSE_FILE" "$candidate_file" "$image" \
    || ! docker_compose -f "$candidate_file" config -q; then
    cleanup_activation
    echo "The preloaded frontend Compose configuration is invalid" >&2
    exit 1
  fi
  if ! mv "$candidate_file" "$COMPOSE_FILE"; then
    cleanup_activation
    echo "Unable to activate the preloaded frontend Compose configuration" >&2
    exit 1
  fi

  activation_failed=false
  if ! docker_compose up -d --no-deps --force-recreate frontend; then
    activation_failed=true
  elif ! verify_frontend_activation "$expected_image_id"; then
    activation_failed=true
  fi
  if [ "$activation_failed" = "true" ]; then
    if ! restore_activation_compose "$old_compose_file"; then
      echo "Frontend activation failed and restoring the previous service also failed" >&2
      cleanup_activation
      exit 1
    fi
    cleanup_activation
    echo "Frontend activation failed; the previous service was restored" >&2
    exit 1
  fi

  cleanup_activation
  rm -f -- "$PRELOAD_STATE_FILE"
  echo "activated_image=$image"
  echo "frontend_health=healthy"
  echo "database_untouched=true"
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

wait_for_backend_proxy() {
  attempts=0
  while [ "$attempts" -lt 15 ]; do
    if health_response=$(curl --fail --silent --connect-timeout 1 --max-time 2 \
      "$PRODUCTION_URL/health") \
      && printf '%s' "$health_response" | grep -q '"status":"ok"'; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -lt 15 ]; then
      sleep 2
    fi
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
  if ! wait_for_backend_proxy; then
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

  # Compose v1 records bind-mount destinations in the container's Config.Volumes.
  # Committing that metadata makes file mounts unusable as a rollback-image base.
  base_volume_metadata=$(docker image inspect "$current_image_id" \
    --format '{{json .Config.Volumes}}')
  case "$base_volume_metadata" in
    null|'{}') ;;
    *)
      echo "Production base image declares volumes and cannot be safely reconstructed" >&2
      exit 1
      ;;
  esac
  docker image tag "$current_image_id" "$snapshot_base_ref"
  snapshot_base_id=$(docker image inspect "$snapshot_base_ref" --format '{{.Id}}')
  if [ "$snapshot_base_id" != "$current_image_id" ]; then
    echo "Rollback base image does not match the running frontend image" >&2
    exit 1
  fi
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
  rollback_volume_metadata=$(docker image inspect "$rollback_image_ref" \
    --format '{{json .Config.Volumes}}')
  case "$rollback_volume_metadata" in
    null|'{}') ;;
    *)
      echo "Rollback image unexpectedly declares volumes" >&2
      exit 1
      ;;
  esac
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
  if docker image rm "$snapshot_base_ref" >/dev/null 2>&1; then
    snapshot_base_ref=
  fi
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
  if docker container inspect "$PRODUCTION_CONTAINER" >/dev/null 2>&1; then
    current_image_id=$(docker inspect "$PRODUCTION_CONTAINER" --format '{{.Image}}')
  else
    current_image_id=missing
  fi
  if [ -r "$COMPOSE_FILE" ]; then
    current_compose_sha=$(compose_sha256 "$COMPOSE_FILE")
  else
    current_compose_sha=missing
  fi

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
      elif [ "$current_image_id" = "missing" ] \
        && [ "$current_compose_sha" = "$previous_compose_sha" ]; then
        backup_restore_state=transition
      elif deployment_state_matches "$digest" "$backup_id"; then
        case "$current_image_id" in
          "$previous_image_id"|"$requested_image_id"|"$rollback_image_id"|missing) ;;
          *)
            echo "Refusing to restore against an unrelated frontend image" >&2
            exit 1
            ;;
        esac
        case "$current_compose_sha" in
          "$previous_compose_sha"|"$candidate_compose_sha"|"$rollback_compose_sha"|missing) ;;
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
      skip_service_block = 0
    }
    in_frontend && /^    image:/ {
      print "    image: " image
      found_image = 1
      next
    }
    in_frontend && /^    (volumes|healthcheck):/ {
      skip_service_block = 1
      next
    }
    in_frontend && skip_service_block {
      if (/^      / || /^[[:space:]]*$/) next
      skip_service_block = 0
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
active_digest=
active_backup_id=

restore_active_deploy() {
  if ! (restore_backup "$active_digest" "$active_backup_id"); then
    return 1
  fi
}

restore_failed_deploy() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$rollback_required" = "true" ] \
    && [ -n "$active_digest" ] \
    && [ -n "$active_backup_id" ]; then
    echo "Deployment exited unexpectedly; restoring the verified frontend backup" >&2
    if ! restore_active_deploy; then
      echo "Automatic restore failed; manual intervention is required" >&2
    fi
  fi
  exit "$status"
}

restore_interrupted_deploy() {
  trap - EXIT HUP INT TERM
  if [ "$rollback_required" = "true" ] \
    && [ -n "$active_digest" ] \
    && [ -n "$active_backup_id" ]; then
    echo "Deployment interrupted; restoring the verified frontend backup" >&2
    if ! restore_active_deploy; then
      echo "Automatic restore failed; manual intervention is required" >&2
    fi
  fi
  exit 130
}

fail_deploy_and_restore() {
  trap - EXIT HUP INT TERM
  if ! restore_active_deploy; then
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
  expected_image=$(docker image inspect "$image" --format '{{.Id}}')

  rewrite_frontend_service "$COMPOSE_FILE" "$candidate_file" "$image"
  cd "$APP_DIR"
  docker_compose -f "$candidate_file" config -q
  write_deployment_state "$digest" "$backup_id"
  active_digest=$digest
  active_backup_id=$backup_id
  rollback_required=true
  trap restore_failed_deploy EXIT
  trap restore_interrupted_deploy HUP INT TERM
  mv "$candidate_file" "$COMPOSE_FILE"

  if ! docker_compose up -d --no-deps --force-recreate frontend; then
    fail_deploy_and_restore
  fi

  if ! verify_production "$expected_image" strict; then
    docker logs --tail 80 "$PRODUCTION_CONTAINER" >&2 || true
    fail_deploy_and_restore
  fi

  rollback_required=false
  active_digest=
  active_backup_id=
  trap - EXIT HUP INT TERM

  echo "deployed_image=$image"
  echo "backup_dir=$backup_dir"
  echo "frontend_health=healthy"
}

if [ "${AIFOO_DEPLOY_LIBRARY_ONLY:-0}" != "1" ]; then
  require_root

  command=${1:-}
  case "$command" in
  preflight)
    preflight_readonly "${2:-}"
    ;;
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
  preload)
    preload_digest "${2:-}"
    ;;
  activate)
    activate_frontend_digest "${2:-}"
    ;;
  cleanup-stage)
    cleanup_stage
    ;;
  *)
      echo "Usage: $0 {preflight <helper-sha256>|login <actor>|logout|stage <sha256:digest>|preload <sha256:digest>|activate <sha256:digest>|backup <sha256:digest>|deploy <sha256:digest> <backup-id>|restore <sha256:digest> <backup-id>|cleanup-stage}" >&2
      exit 1
      ;;
  esac
fi
