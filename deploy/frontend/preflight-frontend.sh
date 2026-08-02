#!/usr/bin/env bash

# This script is streamed over SSH. It must remain read-only on the VPS.

set -u

export LC_ALL=C

COMPOSE_PATH=${AIFOO_APP_DIR:-/opt/sub2api}/docker-compose.yml
HELPER_PATH=${AIFOO_DEPLOY_HELPER:-/usr/local/sbin/deploy-sub2api-frontend}
BACKUP_ROOT=${AIFOO_BACKUP_ROOT:-/var/backups/sub2api}
FRONTEND_NAME=${AIFOO_PRODUCTION_CONTAINER:-sub2api-frontend}
STAGE_NETWORK=${AIFOO_STAGE_NETWORK:-sub2api_default}
STAGE_PORT=${AIFOO_STAGE_PORT:-18080}
EXPECTED_HELPER_SHA=${EXPECTED_HELPER_SHA:-}
MIN_AVAILABLE_MEMORY_MB=${AIFOO_MIN_AVAILABLE_MEMORY_MB:-512}
MIN_AVAILABLE_DISK_KB=${AIFOO_MIN_AVAILABLE_DISK_KB:-2097152}

blocker_count=0
warning_count=0

block() {
  blocker_count=$((blocker_count + 1))
  printf 'blocker=%s\n' "$1"
}

warn() {
  warning_count=$((warning_count + 1))
  printf 'warning=%s\n' "$1"
}

file_hash() {
  if [ -r "$1" ]; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'missing\n'
  fi
}

container_fingerprint() {
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

service_fingerprint() {
  for unit_name in docker nginx containerd; do
    printf '%s|' "$unit_name"
    systemctl show "$unit_name" \
      --property=ActiveState \
      --property=SubState \
      --value 2>/dev/null | tr '\n' ':' || true
    printf '\n'
  done | sha256sum | awk '{print $1}'
}

compose_hash_before=$(file_hash "$COMPOSE_PATH")
helper_hash_before=$(file_hash "$HELPER_PATH")
containers_before=$(container_fingerprint)
services_before=$(service_fingerprint)

printf 'preflight_time_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'preflight_user=%s uid=%s\n' "$(id -un)" "$(id -u)"

if [ "$(id -u)" -ne 0 ]; then
  block preflight_user_is_not_root
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
if [ -z "$available_memory_mb" ] || [ "$available_memory_mb" -lt "$MIN_AVAILABLE_MEMORY_MB" ]; then
  block insufficient_available_memory
fi

if [ -e /opt/sub2api ]; then
  available_disk_kb=$(df -Pk /opt/sub2api | awk 'NR == 2 {print $4}')
else
  available_disk_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
fi
printf 'available_disk_kb=%s\n' "$available_disk_kb"
if [ -z "$available_disk_kb" ] || [ "$available_disk_kb" -lt "$MIN_AVAILABLE_DISK_KB" ]; then
  block insufficient_available_disk
fi

for unit_name in docker nginx containerd; do
  unit_state=$(systemctl is-active "$unit_name" 2>/dev/null || true)
  printf 'service[%s]=%s\n' "$unit_name" "$unit_state"
  if [ "$unit_state" != "active" ]; then
    block "service_${unit_name}_not_active"
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  block docker_missing
else
  docker_client=$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)
  docker_server=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  printf 'docker_client=%s docker_server=%s\n' "$docker_client" "$docker_server"
  if [ -z "$docker_client" ] || [ -z "$docker_server" ]; then
    block docker_unavailable
  fi
fi

compose_command=missing
if docker compose version >/dev/null 2>&1; then
  compose_command=v2
  compose_version=$(docker compose version --short 2>/dev/null || true)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_command=v1
  compose_version=$(docker-compose version --short 2>/dev/null || true)
else
  compose_version=
  block docker_compose_missing
fi
printf 'compose_command=%s compose_version=%s\n' "$compose_command" "$compose_version"

if [ ! -r "$COMPOSE_PATH" ]; then
  block compose_missing_or_unreadable
else
  compose_owner=$(stat -c '%U' "$COMPOSE_PATH")
  compose_mode=$(stat -c '%a' "$COMPOSE_PATH")
  printf 'compose_owner=%s compose_mode=%s compose_sha256=%s\n' \
    "$compose_owner" "$compose_mode" "$compose_hash_before"
  if [ "$compose_owner" != "root" ]; then
    block compose_not_owned_by_root
  fi

  if [ "$compose_command" = "v2" ]; then
    compose_services=$(docker compose -f "$COMPOSE_PATH" config --services 2>/dev/null | sort)
  elif [ "$compose_command" = "v1" ]; then
    compose_services=$(docker-compose -f "$COMPOSE_PATH" config --services 2>/dev/null | sort)
  else
    compose_services=
  fi
  printf 'compose_services=%s\n' "$(printf '%s\n' "$compose_services" | paste -sd, -)"
  for required_service in frontend postgres redis sub2api; do
    if ! printf '%s\n' "$compose_services" | grep -Fxq "$required_service"; then
      block "compose_service_${required_service}_missing"
    fi
  done
fi

if ! docker network inspect "$STAGE_NETWORK" >/dev/null 2>&1; then
  block staging_network_missing
else
  printf 'staging_network=%s\n' "$STAGE_NETWORK"
fi

if ss -lntH 2>/dev/null \
  | awk '{print $4}' \
  | awk -F: -v port="$STAGE_PORT" '$NF == port {found=1} END {exit !found}'; then
  block staging_port_occupied
else
  printf 'staging_port_%s=free\n' "$STAGE_PORT"
fi

for required_container in sub2api sub2api-postgres sub2api-redis "$FRONTEND_NAME"; do
  if ! docker container inspect "$required_container" >/dev/null 2>&1; then
    block "container_${required_container}_missing"
    continue
  fi

  container_state=$(docker inspect "$required_container" --format '{{.State.Status}}')
  container_restarts=$(docker inspect "$required_container" --format '{{.RestartCount}}')
  printf 'container[%s]_state=%s restarts=%s\n' \
    "$required_container" "$container_state" "$container_restarts"
  if [ "$container_state" != "running" ]; then
    block "container_${required_container}_not_running"
  fi
done

if docker container inspect "$FRONTEND_NAME" >/dev/null 2>&1; then
  frontend_image_ref=$(docker inspect "$FRONTEND_NAME" --format '{{.Config.Image}}')
  frontend_health=$(docker inspect "$FRONTEND_NAME" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
  frontend_ports=$(docker port "$FRONTEND_NAME" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  printf 'frontend_image_ref=%s health=%s ports=%s\n' \
    "$frontend_image_ref" "$frontend_health" "$frontend_ports"

  if ! printf '%s\n' "$frontend_ports" | grep -Fq '127.0.0.1:8080'; then
    block frontend_loopback_port_mapping_missing
  fi

  mount_destinations=$(docker inspect "$FRONTEND_NAME" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}')
  printf 'frontend_mount_destinations=%s\n' \
    "$(printf '%s\n' "$mount_destinations" | sed '/^$/d' | sort | paste -sd, -)"
  unsupported_mounts=$(printf '%s\n' "$mount_destinations" | awk '
    NF && !/^\/etc\/nginx(\/|$)/ && !/^\/usr\/share\/nginx\/html(\/|$)/ { print }
  ')
  if [ -n "$unsupported_mounts" ]; then
    block unsupported_frontend_mounts
    printf 'unsupported_mount_destinations=%s\n' \
      "$(printf '%s\n' "$unsupported_mounts" | paste -sd, -)"
  else
    printf 'frontend_mounts_compatible=true\n'
  fi
fi

health_response=$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
  --write-out '\n%{http_code}' http://127.0.0.1:8080/health 2>/dev/null || true)
health_code=$(printf '%s\n' "$health_response" | tail -n 1)
health_body=$(printf '%s\n' "$health_response" | sed '$d')
printf 'internal_health_code=%s\n' "$health_code"
if [ "$health_code" != "200" ] \
  || ! printf '%s' "$health_body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  block internal_health_failed
fi

frontend_health_response=$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
  --write-out '\n%{http_code}' http://127.0.0.1:8080/frontend-health 2>/dev/null || true)
frontend_health_code=$(printf '%s\n' "$frontend_health_response" | tail -n 1)
frontend_health_body=$(printf '%s\n' "$frontend_health_response" | sed '$d')
if printf '%s' "$frontend_health_body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  printf 'current_frontend_contract=candidate-health-endpoint\n'
elif printf '%s' "$frontend_health_body" | grep -q '<div id="app"></div>'; then
  printf 'current_frontend_contract=legacy-spa-fallback\n'
else
  printf 'current_frontend_contract=unknown code=%s\n' "$frontend_health_code"
  warn frontend_health_contract_unknown
fi

if [ ! -x "$HELPER_PATH" ]; then
  block deploy_helper_missing_or_not_executable
else
  helper_owner=$(stat -c '%U' "$HELPER_PATH")
  helper_mode=$(stat -c '%a' "$HELPER_PATH")
  helper_hash=$(file_hash "$HELPER_PATH")
  printf 'deploy_helper_owner=%s mode=%s sha256=%s\n' \
    "$helper_owner" "$helper_mode" "$helper_hash"
  if [ "$helper_owner" != "root" ]; then
    block deploy_helper_not_owned_by_root
  fi
  if find "$HELPER_PATH" -perm /022 -print -quit 2>/dev/null | grep -q .; then
    block deploy_helper_group_or_world_writable
  fi
  if ! printf '%s' "$EXPECTED_HELPER_SHA" | grep -Eq '^[0-9a-f]{64}$'; then
    block expected_helper_sha_missing_or_invalid
  elif [ "$helper_hash" != "$EXPECTED_HELPER_SHA" ]; then
    block deploy_helper_sha_mismatch
  fi
fi

if [ -e "$BACKUP_ROOT" ]; then
  backup_owner=$(stat -c '%U' "$BACKUP_ROOT")
  backup_mode=$(stat -c '%a' "$BACKUP_ROOT")
  printf 'backup_root=present owner=%s mode=%s\n' "$backup_owner" "$backup_mode"
  if [ "$backup_owner" != "root" ]; then
    block backup_root_not_owned_by_root
  fi
  if [ "$backup_mode" != "700" ]; then
    warn backup_root_will_be_hardened_during_authorized_backup
  fi
else
  printf 'backup_root=absent\n'
  warn backup_root_will_be_created_during_authorized_backup
fi

compose_hash_after=$(file_hash "$COMPOSE_PATH")
helper_hash_after=$(file_hash "$HELPER_PATH")
containers_after=$(container_fingerprint)
services_after=$(service_fingerprint)

if [ "$compose_hash_before" != "$compose_hash_after" ]; then
  block compose_changed_during_preflight
fi
if [ "$helper_hash_before" != "$helper_hash_after" ]; then
  block deploy_helper_changed_during_preflight
fi
if [ "$containers_before" != "$containers_after" ]; then
  block container_state_changed_during_preflight
fi
if [ "$services_before" != "$services_after" ]; then
  block service_state_changed_during_preflight
fi

printf 'compose_unchanged=%s\n' "$([ "$compose_hash_before" = "$compose_hash_after" ] && printf true || printf false)"
printf 'helper_unchanged=%s\n' "$([ "$helper_hash_before" = "$helper_hash_after" ] && printf true || printf false)"
printf 'containers_unchanged=%s\n' "$([ "$containers_before" = "$containers_after" ] && printf true || printf false)"
printf 'services_unchanged=%s\n' "$([ "$services_before" = "$services_after" ] && printf true || printf false)"
printf 'warning_count=%s blocker_count=%s\n' "$warning_count" "$blocker_count"

if [ "$blocker_count" -ne 0 ]; then
  printf 'preflight_result=blocked\n'
  exit 1
fi

printf 'preflight_result=ready\n'
