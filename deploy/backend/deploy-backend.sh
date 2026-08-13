#!/bin/sh

set -eu

APP_DIR=${AIFOO_APP_DIR:-/opt/sub2api}
COMPOSE_FILE=${AIFOO_COMPOSE_FILE:-$APP_DIR/docker-compose.yml}
BACKUP_ROOT=${AIFOO_BACKUP_ROOT:-/var/backups/sub2api}
IMAGE_REPOSITORY=${AIFOO_BACKEND_IMAGE_REPOSITORY:-weishaw/sub2api}
BACKEND_CONTAINER=${AIFOO_BACKEND_CONTAINER:-sub2api}
FRONTEND_CONTAINER=${AIFOO_FRONTEND_CONTAINER:-sub2api-frontend}
POSTGRES_CONTAINER=${AIFOO_POSTGRES_CONTAINER:-sub2api-postgres}
REDIS_CONTAINER=${AIFOO_REDIS_CONTAINER:-sub2api-redis}
PRODUCTION_URL=${AIFOO_PRODUCTION_URL:-http://127.0.0.1:8080}
DEPLOYMENT_STATE_FILE=$APP_DIR/.aifoo-backend-deployment-state
PREPARED_ROOT=$APP_DIR/.aifoo-backend-prepared
MUTATION_LOCK_FILE=${AIFOO_BACKEND_LOCK_FILE:-/run/lock/aifoo-backend-deploy.lock}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This command must run as root" >&2
    exit 1
  fi
}

acquire_mutation_lock() {
  umask 077
  exec 9>"$MUTATION_LOCK_FILE"
  if ! flock -n 9; then
    echo "Another backend deployment command is already running" >&2
    exit 1
  fi
}

docker_compose() {
  docker-compose -f "$COMPOSE_FILE" "$@"
}

validate_digest() {
  if ! printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "Expected sha256:<64 lowercase hex characters>" >&2
    exit 1
  fi
}

validate_release_tag() {
  if ! printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Expected a stable vX.Y.Z release tag" >&2
    exit 1
  fi
}

validate_commit() {
  if ! printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "Expected a 40-character lowercase Git commit" >&2
    exit 1
  fi
}

validate_migrations() {
  migrations=$1
  if [ "$migrations" = "none" ]; then
    return
  fi
  if ! printf '%s' "$migrations" \
    | grep -Eq '^[0-9]{3}_[a-z0-9_]+(_notx)?\.sql(,[0-9]{3}_[a-z0-9_]+(_notx)?\.sql)*$'; then
    echo "Expected none or a comma-separated migration filename list" >&2
    exit 1
  fi
}

validate_backup_id() {
  if ! printf '%s' "$1" \
    | grep -Eq '^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]{6}-postgres-v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Invalid backend backup ID" >&2
    exit 1
  fi
}

is_sha256() {
  printf '%s' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'
}

is_hex_sha256() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

is_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

image_ref() {
  printf '%s@%s\n' "$IMAGE_REPOSITORY" "$1"
}

compose_sha256() {
  sha256sum "$COMPOSE_FILE" | awk '{print $1}'
}

container_field() {
  docker inspect "$1" --format "$2"
}

container_signature() {
  container=$1
  container_field "$container" \
    '{{.Id}}|{{.Image}}|{{.State.StartedAt}}|{{json .Mounts}}|{{json .NetworkSettings.Networks}}'
}

companion_signatures() {
  for container in "$FRONTEND_CONTAINER" "$POSTGRES_CONTAINER" "$REDIS_CONTAINER"; do
    printf '%s=' "$container"
    container_signature "$container"
  done
}

backend_version_output() {
  docker exec "$BACKEND_CONTAINER" /app/sub2api --version 2>&1
}

image_version_output() {
  docker run --rm --network none --entrypoint /app/sub2api "$1" --version 2>&1
}

version_from_output() {
  printf '%s\n' "$1" \
    | grep -oE 'Sub2API v?[0-9]+\.[0-9]+\.[0-9]+' \
    | tail -n 1 \
    | awk '{sub(/^v/, "", $2); print $2}'
}

commit_from_output() {
  printf '%s\n' "$1" \
    | grep -oE 'commit: [0-9a-f]{40}' \
    | tail -n 1 \
    | awk '{print $2}'
}

verify_version_output() {
  output=$1
  release_tag=$2
  release_commit=$3
  actual_version=$(version_from_output "$output")
  actual_commit=$(commit_from_output "$output")
  expected_version=${release_tag#v}
  if [ "$actual_version" != "$expected_version" ] \
    || [ "$actual_commit" != "$release_commit" ]; then
    echo "Backend version provenance does not match the official release" >&2
    return 1
  fi
}

postgres_query() {
  sql=$1
  docker exec "$POSTGRES_CONTAINER" sh -c \
    'exec psql -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' \
    sh "$sql"
}

redis_command() {
  docker exec "$REDIS_CONTAINER" sh -c '
    if [ -n "${REDIS_PASSWORD:-}" ]; then
      exec redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@"
    fi
    exec redis-cli "$@"
  ' sh "$@"
}

quota_flusher_state() {
  docker exec "$BACKEND_CONTAINER" sh -c '
    value=${DATABASE_USER_PLATFORM_QUOTA_FLUSHER_ENABLED:-}
    if [ -z "$value" ]; then
      config_file=${CONFIG_FILE:-${DATA_DIR:-/app/data}/config.yaml}
      if [ -r "$config_file" ]; then
        value=$(awk '\''
          /^[^[:space:]#][^:]*:/ { in_database = ($1 == "database:") }
          in_database && /^[[:space:]]+user_platform_quota_flusher_enabled:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/[[:space:]#].*$/, "")
            print tolower($0)
            exit
          }
        '\'' "$config_file")
      fi
    fi
    printf "%s\n" "${value:-false}" | tr "[:upper:]" "[:lower:]"
  '
}

schema_migration_snapshot() {
  postgres_query \
    'SELECT filename || E'\''\t'\'' || checksum || E'\''\t'\'' || applied_at::text FROM schema_migrations ORDER BY filename;'
}

verify_expected_migrations() {
  migrations=$1
  if [ "$migrations" = "none" ]; then
    postgres_query 'SELECT COUNT(*) FROM schema_migrations;' >/dev/null
    return
  fi

  old_ifs=$IFS
  IFS=,
  for migration in $migrations; do
    count=$(postgres_query \
      "SELECT COUNT(*) FROM schema_migrations WHERE filename = '$migration';")
    if [ "$count" != "1" ]; then
      echo "Expected database migration was not applied: $migration" >&2
      IFS=$old_ifs
      return 1
    fi
  done
  IFS=$old_ifs
}

verify_backend_health() {
  expected_image_id=$1
  release_tag=$2
  release_commit=$3
  attempts=0
  while [ "$attempts" -lt 30 ]; do
    actual_image_id=$(container_field "$BACKEND_CONTAINER" '{{.Image}}' 2>/dev/null || true)
    state=$(container_field "$BACKEND_CONTAINER" '{{.State.Status}}' 2>/dev/null || true)
    health=$(container_field "$BACKEND_CONTAINER" \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)
    if [ "$actual_image_id" = "$expected_image_id" ] \
      && [ "$state" = "running" ] \
      && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; } \
      && output=$(backend_version_output) \
      && verify_version_output "$output" "$release_tag" "$release_commit" \
      && curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
        "$PRODUCTION_URL/health" | grep -q '"status":"ok"'; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -lt 30 ]; then
      sleep 2
    fi
  done
  echo "Backend did not become healthy with the expected version and image" >&2
  return 1
}

metadata_value() {
  key=$1
  file=$2
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

prepared_dir() {
  digest=$1
  validate_digest "$digest"
  printf '%s/%s\n' "$PREPARED_ROOT" "${digest#sha256:}"
}

write_deployment_state() {
  digest=$1
  migrations=$2
  data_backup_id=$3
  state_tmp=$(mktemp "$APP_DIR/.aifoo-backend-state.XXXXXX")
  {
    printf 'digest=%s\n' "$digest"
    printf 'migrations=%s\n' "$migrations"
    printf 'data_backup_id=%s\n' "$data_backup_id"
  } > "$state_tmp"
  chmod 600 "$state_tmp"
  mv "$state_tmp" "$DEPLOYMENT_STATE_FILE"
}

rewrite_backend_service() {
  source=$1
  output=$2
  replacement_image=$3
  awk -v image="$replacement_image" '
    /^  sub2api:/ {
      in_backend = 1
      found_backend = 1
      print
      next
    }
    in_backend && /^  [[:alnum:]_-]+:/ {
      in_backend = 0
    }
    in_backend && /^    image:/ {
      print "    image: " image
      found_image = 1
      next
    }
    { print }
    END {
      if (!found_backend || !found_image) exit 42
    }
  ' "$source" > "$output"
}

# BEGIN READ-ONLY PREFLIGHT
preflight_readonly() {
  expected_helper_sha=$1
  digest=$2
  release_tag=$3
  release_commit=$4
  migrations=${5:-none}
  blocker_count=0

  block() {
    blocker_count=$((blocker_count + 1))
    printf 'blocker=%s\n' "$1"
  }

  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"

  compose_before=$(sha256sum "$COMPOSE_FILE" 2>/dev/null | awk '{print $1}' || true)
  containers_before=$(companion_signatures 2>/dev/null | sha256sum | awk '{print $1}' || true)
  helper_sha=$(sha256sum "$0" 2>/dev/null | awk '{print $1}' || true)

  printf 'preflight_time_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'deploy_helper_sha256=%s\n' "$helper_sha"
  if ! printf '%s' "$expected_helper_sha" | grep -Eq '^[0-9a-f]{64}$'; then
    block invalid_expected_helper_sha
  elif [ "$helper_sha" != "$expected_helper_sha" ]; then
    block deploy_helper_sha_mismatch
  fi
  if [ "$(stat -c '%U' "$0" 2>/dev/null || true)" != "root" ]; then
    block deploy_helper_not_owned_by_root
  fi
  if find "$0" -perm /022 -print -quit 2>/dev/null | grep -q .; then
    block deploy_helper_group_or_world_writable
  fi

  for command_name in docker docker-compose curl sha256sum awk sed df flock; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      block "command_${command_name}_missing"
    fi
  done
  if [ ! -r "$COMPOSE_FILE" ]; then
    block compose_missing_or_unreadable
  else
    if [ "$(stat -c '%U' "$COMPOSE_FILE" 2>/dev/null || true)" != "root" ]; then
      block compose_not_owned_by_root
    fi
    if find "$COMPOSE_FILE" -perm /022 -print -quit 2>/dev/null | grep -q .; then
      block compose_group_or_world_writable
    fi
    services=$(docker_compose config --services 2>/dev/null || true)
    for service in sub2api postgres redis frontend; do
      if ! printf '%s\n' "$services" | grep -Fxq "$service"; then
        block "compose_service_${service}_missing"
      fi
    done
  fi
  available_disk_kb=$(df -Pk "$APP_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
  required_backup_kb=0
  backup_policy=none
  if [ "$migrations" != "none" ]; then
    backup_policy=postgresql
    if [ ! -d "$BACKUP_ROOT" ]; then
      block backup_root_missing
    else
      if [ "$(stat -c '%U' "$BACKUP_ROOT" 2>/dev/null || true)" != "root" ]; then
        block backup_root_not_owned_by_root
      fi
      if find "$BACKUP_ROOT" -maxdepth 0 -perm /077 -print -quit 2>/dev/null | grep -q .; then
        block backup_root_permissions_too_open
      fi
    fi
    database_size_bytes=$(postgres_query \
      'SELECT pg_database_size(current_database());' 2>/dev/null || true)
    if ! printf '%s' "$database_size_bytes" | grep -Eq '^[0-9]+$'; then
      block backup_size_estimate_failed
      required_backup_kb=
    else
      required_backup_kb=$((database_size_bytes / 1024 + 262144))
    fi
  fi
  printf 'backup_policy=%s\n' "$backup_policy"
  printf 'available_disk_kb=%s\n' "${available_disk_kb:-unknown}"
  printf 'required_backup_disk_kb=%s\n' "${required_backup_kb:-unknown}"
  if [ -z "$available_disk_kb" ] \
    || [ -z "$required_backup_kb" ] \
    || [ "$available_disk_kb" -lt "$required_backup_kb" ]; then
    block insufficient_backup_disk
  fi

  for container in "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" "$POSTGRES_CONTAINER" "$REDIS_CONTAINER"; do
    if ! docker container inspect "$container" >/dev/null 2>&1; then
      block "container_${container}_missing"
      continue
    fi
    state=$(container_field "$container" '{{.State.Status}}')
    health=$(container_field "$container" \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
    restarts=$(container_field "$container" '{{.RestartCount}}')
    printf 'container[%s]_state=%s health=%s restarts=%s\n' \
      "$container" "$state" "$health" "$restarts"
    if [ "$state" != "running" ] \
      || { [ "$health" != "healthy" ] && [ "$health" != "none" ]; }; then
      block "container_${container}_not_healthy"
    fi
  done

  if ! postgres_query 'SELECT 1;' >/dev/null 2>&1; then
    block postgres_read_check_failed
  fi
  if [ "$(redis_command PING 2>/dev/null || true)" != "PONG" ]; then
    block redis_ping_failed
  fi
  if ! curl --fail --silent --show-error --connect-timeout 2 --max-time 5 \
    "$PRODUCTION_URL/health" 2>/dev/null | grep -q '"status":"ok"'; then
    block backend_local_health_failed
  fi

  target_state=different
  target_ref=$(image_ref "$digest")
  current_ref=$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)
  current_output=$(backend_version_output 2>/dev/null || true)
  current_version=$(version_from_output "$current_output" || true)
  current_commit=$(commit_from_output "$current_output" || true)
  current_digest=${current_ref#"$IMAGE_REPOSITORY"@}
  if [ "$current_ref" = "$current_digest" ] || ! is_sha256 "$current_digest"; then
    block current_backend_image_not_immutable
  fi
  if ! printf '%s' "$current_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || ! printf '%s' "$current_commit" | grep -Eq '^[0-9a-f]{40}$'; then
    block current_backend_provenance_invalid
  fi
  if [ "$current_ref" = "$target_ref" ] \
    && verify_version_output "$current_output" "$release_tag" "$release_commit" 2>/dev/null; then
    target_state=current
  fi
  printf 'backend_image_ref=%s\n' "$current_ref"
  printf 'current_release=v%s\n' "$current_version"
  printf 'current_commit=%s\n' "$current_commit"
  printf 'target_state=%s\n' "$target_state"

  compose_after=$(sha256sum "$COMPOSE_FILE" 2>/dev/null | awk '{print $1}' || true)
  containers_after=$(companion_signatures 2>/dev/null | sha256sum | awk '{print $1}' || true)
  compose_unchanged=false
  containers_unchanged=false
  [ "$compose_before" = "$compose_after" ] && compose_unchanged=true
  [ "$containers_before" = "$containers_after" ] && containers_unchanged=true
  printf 'compose_unchanged=%s\n' "$compose_unchanged"
  printf 'containers_unchanged=%s\n' "$containers_unchanged"
  if [ "$compose_unchanged" != "true" ]; then
    block preflight_changed_compose
  fi
  if [ "$containers_unchanged" != "true" ]; then
    block preflight_changed_companion_containers
  fi

  if [ "$blocker_count" -ne 0 ]; then
    printf 'preflight_result=blocked blocker_count=%s\n' "$blocker_count"
    return 1
  fi
  printf 'preflight_result=ready\n'
}
# END READ-ONLY PREFLIGHT

stage_image() {
  digest=$1
  release_tag=$2
  release_commit=$3
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  image=$(image_ref "$digest")
  docker pull "$image" >/dev/null
  source_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
  revision_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
  version_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
  if [ "$source_label" != "https://github.com/Wei-Shaw/sub2api" ] \
    || [ "$revision_label" != "$release_commit" ] \
    || [ "$version_label" != "${release_tag#v}" ]; then
    echo "Official backend image labels do not match the requested release" >&2
    exit 1
  fi
  version_output=$(image_version_output "$image")
  verify_version_output "$version_output" "$release_tag" "$release_commit"
  printf 'staged_image=%s\n' "$image"
  printf 'staged_release=%s\n' "$release_tag"
  printf 'staged_commit=%s\n' "$release_commit"
}

prepare_backend() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"

  target=$(image_ref "$digest")
  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)" = "$target" ]; then
    expected_image_id=$(docker image inspect "$target" --format '{{.Id}}')
    verify_backend_health "$expected_image_id" "$release_tag" "$release_commit"
    verify_expected_migrations "$migrations"
    printf 'prepare_state=already-current\n'
    printf 'backup_policy=already-current\n'
    return
  fi

  if [ "$migrations" != "none" ]; then
    if ! quota_flusher_enabled=$(quota_flusher_state 2>/dev/null); then
      echo "Unable to determine the quota flusher state before preparation" >&2
      return 1
    fi
    case "$quota_flusher_enabled" in
      true|1|yes|on)
        echo "Migration updates require manual preparation while the quota flusher is enabled" >&2
        return 1
        ;;
      false|0|no|off) ;;
      *)
        echo "Unable to determine the quota flusher state before preparation" >&2
        return 1
        ;;
    esac
  fi

  stage_image "$digest" "$release_tag" "$release_commit" >/dev/null
  image=$(image_ref "$digest")
  target_image_id=$(docker image inspect "$image" --format '{{.Id}}')
  previous_image_ref=$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}')
  previous_image_id=$(container_field "$BACKEND_CONTAINER" '{{.Image}}')
  previous_version_output=$(backend_version_output)
  previous_version=$(version_from_output "$previous_version_output")
  previous_commit=$(commit_from_output "$previous_version_output")
  if ! is_sha256 "$previous_image_id" \
    || [ "${previous_image_ref#"$IMAGE_REPOSITORY"@}" = "$previous_image_ref" ] \
    || ! is_sha256 "${previous_image_ref#"$IMAGE_REPOSITORY"@}" \
    || ! is_version "$previous_version" \
    || ! printf '%s' "$previous_commit" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "Unable to record the current backend rollback provenance" >&2
    return 1
  fi
  original_compose_sha=$(compose_sha256)
  prepared=$(prepared_dir "$digest")
  work_dir=$(mktemp -d "$APP_DIR/.aifoo-backend-prepare.XXXXXX")
  cleanup_prepare() {
    status=$1
    trap - EXIT HUP INT TERM
    case "$work_dir" in
      "$APP_DIR"/.aifoo-backend-prepare.*) rm -rf -- "$work_dir" ;;
    esac
    exit "$status"
  }
  trap 'cleanup_prepare $?' EXIT
  trap 'cleanup_prepare 129' HUP
  trap 'cleanup_prepare 130' INT
  trap 'cleanup_prepare 143' TERM
  cp "$COMPOSE_FILE" "$work_dir/original-compose.yml"
  rewrite_backend_service "$work_dir/original-compose.yml" "$work_dir/candidate-compose.yml" "$image"
  rewrite_backend_service "$work_dir/original-compose.yml" "$work_dir/rollback-compose.yml" "$previous_image_ref"
  docker-compose -f "$work_dir/candidate-compose.yml" config -q
  docker-compose -f "$work_dir/rollback-compose.yml" config -q
  companion_signatures > "$work_dir/companion-containers.txt"
  {
    printf 'digest=%s\n' "$digest"
    printf 'release_tag=%s\n' "$release_tag"
    printf 'release_commit=%s\n' "$release_commit"
    printf 'migrations=%s\n' "$migrations"
    printf 'target_image_id=%s\n' "$target_image_id"
    printf 'previous_image_ref=%s\n' "$previous_image_ref"
    printf 'previous_image_id=%s\n' "$previous_image_id"
    printf 'previous_version=%s\n' "$previous_version"
    printf 'previous_commit=%s\n' "$previous_commit"
    printf 'compose_sha256=%s\n' "$original_compose_sha"
    printf 'candidate_compose_sha256=%s\n' "$(sha256sum "$work_dir/candidate-compose.yml" | awk '{print $1}')"
    printf 'rollback_compose_sha256=%s\n' "$(sha256sum "$work_dir/rollback-compose.yml" | awk '{print $1}')"
  } > "$work_dir/metadata.env"
  (
    cd "$work_dir"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  )
  chmod 700 "$work_dir"
  chmod 600 "$work_dir"/*
  mkdir -p "$PREPARED_ROOT"
  rm -rf -- "$prepared"
  mv "$work_dir" "$prepared"
  trap - EXIT HUP INT TERM
  require_prepared "$digest" "$release_tag" "$release_commit" "$migrations"
  printf 'prepare_state=ready\n'
  printf 'backup_policy=%s\n' "$([ "$migrations" = none ] && printf none || printf postgresql)"
}

require_prepared() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"

  prepared=$(prepared_dir "$digest")
  metadata=$prepared/metadata.env
  [ -d "$prepared" ] && [ -r "$metadata" ] && [ -r "$prepared/SHA256SUMS" ] \
    || { echo "Prepared backend state is missing" >&2; return 1; }
  (
    cd "$prepared"
    sha256sum -c SHA256SUMS >/dev/null
  ) || { echo "Prepared backend state checksum verification failed" >&2; return 1; }
  for required in original-compose.yml candidate-compose.yml rollback-compose.yml companion-containers.txt metadata.env SHA256SUMS; do
    [ -s "$prepared/$required" ] || { echo "Prepared backend state is incomplete: $required" >&2; return 1; }
  done
  prepared_digest=$(metadata_value digest "$metadata")
  prepared_release=$(metadata_value release_tag "$metadata")
  prepared_commit=$(metadata_value release_commit "$metadata")
  prepared_migrations=$(metadata_value migrations "$metadata")
  target_image_id=$(metadata_value target_image_id "$metadata")
  previous_image_ref=$(metadata_value previous_image_ref "$metadata")
  previous_image_id=$(metadata_value previous_image_id "$metadata")
  previous_version=$(metadata_value previous_version "$metadata")
  previous_commit=$(metadata_value previous_commit "$metadata")
  baseline_compose_sha=$(metadata_value compose_sha256 "$metadata")
  current_image_ref=$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)
  current_image_id=$(container_field "$BACKEND_CONTAINER" '{{.Image}}' 2>/dev/null || true)
  current_output=$(backend_version_output 2>/dev/null || true)
  if [ "$prepared_digest" != "$digest" ] \
    || [ "$prepared_release" != "$release_tag" ] \
    || [ "$prepared_commit" != "$release_commit" ] \
    || [ "$prepared_migrations" != "$migrations" ] \
    || [ "$current_image_ref" != "$previous_image_ref" ] \
    || [ "$current_image_id" != "$previous_image_id" ] \
    || [ "$(version_from_output "$current_output" || true)" != "$previous_version" ] \
    || [ "$(commit_from_output "$current_output" || true)" != "$previous_commit" ] \
    || [ "$(compose_sha256)" != "$baseline_compose_sha" ] \
    || [ "$(docker image inspect "$previous_image_ref" --format '{{.Id}}' 2>/dev/null || true)" != "$previous_image_id" ] \
    || [ "$(docker image inspect "$(image_ref "$digest")" --format '{{.Id}}' 2>/dev/null || true)" != "$target_image_id" ]; then
    echo "Prepared backend state is stale" >&2
    return 1
  fi
  docker-compose -f "$prepared/candidate-compose.yml" config -q
  docker-compose -f "$prepared/rollback-compose.yml" config -q
  verify_companions_unchanged "$prepared"
}

prepared_backend_status() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"
  target=$(image_ref "$digest")
  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)" = "$target" ]; then
    expected_image_id=$(docker image inspect "$target" --format '{{.Id}}')
    verify_backend_health "$expected_image_id" "$release_tag" "$release_commit"
    verify_expected_migrations "$migrations"
    printf 'prepared_state=already-current\n'
    printf 'backup_policy=already-current\n'
    return
  fi
  require_prepared "$1" "$2" "$3" "$4"
  printf 'prepared_state=ready\n'
  printf 'backup_policy=%s\n' "$([ "$4" = none ] && printf none || printf postgresql)"
}

create_data_backup() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"
  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)" = "$(image_ref "$digest")" ]; then
    printf 'backup_id=none\n'
    printf 'backup_verified=not-required\n'
    printf 'backup_policy=already-current\n'
    return
  fi
  if [ "$migrations" = "none" ]; then
    printf 'backup_id=none\n'
    printf 'backup_verified=not-required\n'
    printf 'backup_policy=none\n'
    return
  fi
  require_prepared "$digest" "$release_tag" "$release_commit" "$migrations"

  if ! quota_flusher_enabled=$(quota_flusher_state 2>/dev/null); then
    echo "Unable to determine the quota flusher state before PostgreSQL backup" >&2
    return 1
  fi
  case "$quota_flusher_enabled" in
    true|1|yes|on)
      echo "PostgreSQL backup requires the quota flusher to remain disabled" >&2
      return 1
      ;;
    false|0|no|off) ;;
    *)
      echo "Unable to determine the quota flusher state before PostgreSQL backup" >&2
      return 1
      ;;
  esac

  umask 077
  mkdir -p "$BACKUP_ROOT"
  random_suffix=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  backup_id="$(date -u +%Y%m%d-%H%M%S)-${random_suffix}-postgres-$release_tag"
  validate_backup_id "$backup_id"
  backup_dir=$BACKUP_ROOT/$backup_id
  mkdir "$backup_dir"
  cleanup_incomplete_backup() {
    status=$1
    trap - EXIT HUP INT TERM
    case "$backup_dir" in
      "$BACKUP_ROOT"/*-postgres-v*) rm -rf -- "$backup_dir" ;;
    esac
    exit "$status"
  }
  trap 'cleanup_incomplete_backup $?' EXIT
  trap 'cleanup_incomplete_backup 129' HUP
  trap 'cleanup_incomplete_backup 130' INT
  trap 'cleanup_incomplete_backup 143' TERM
  docker exec "$POSTGRES_CONTAINER" sh -c \
    'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-privileges' \
    > "$backup_dir/postgres.dump"
  docker exec -i "$POSTGRES_CONTAINER" pg_restore --list \
    < "$backup_dir/postgres.dump" >/dev/null
  {
    printf 'backup_id=%s\n' "$backup_id"
    printf 'created_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'target_digest=%s\n' "$digest"
    printf 'target_release=%s\n' "$release_tag"
    printf 'target_commit=%s\n' "$release_commit"
    printf 'expected_migrations=%s\n' "$migrations"
    printf 'compose_sha256=%s\n' "$(compose_sha256)"
  } > "$backup_dir/metadata.env"
  (
    cd "$backup_dir"
    sha256sum postgres.dump metadata.env > SHA256SUMS
  )
  chmod 700 "$backup_dir"
  require_data_backup "$digest" "$release_tag" "$release_commit" "$migrations" "$backup_id"
  trap - EXIT HUP INT TERM
  printf 'backup_id=%s\n' "$backup_id"
  printf 'backup_verified=true\n'
  printf 'backup_policy=postgresql\n'
}

require_data_backup() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  backup_id=$5
  validate_digest "$digest"
  validate_release_tag "$release_tag"
  validate_commit "$release_commit"
  validate_migrations "$migrations"
  if [ "$migrations" = "none" ]; then
    [ "$backup_id" = "none" ] \
      || { echo "A migration-free update must not use a data backup" >&2; return 1; }
    return
  fi
  validate_backup_id "$backup_id"
  backup_dir=$BACKUP_ROOT/$backup_id
  for required in postgres.dump metadata.env SHA256SUMS; do
    [ -f "$backup_dir/$required" ] && [ ! -L "$backup_dir/$required" ] \
      && [ -s "$backup_dir/$required" ] \
      || { echo "PostgreSQL backup is incomplete: $required" >&2; return 1; }
  done
  (
    cd "$backup_dir"
    sha256sum -c SHA256SUMS >/dev/null
  ) || { echo "PostgreSQL backup checksum verification failed" >&2; return 1; }
  docker exec -i "$POSTGRES_CONTAINER" pg_restore --list \
    < "$backup_dir/postgres.dump" >/dev/null \
    || { echo "PostgreSQL backup catalog verification failed" >&2; return 1; }
  metadata=$backup_dir/metadata.env
  [ "$(metadata_value backup_id "$metadata")" = "$backup_id" ] \
    && [ "$(metadata_value target_digest "$metadata")" = "$digest" ] \
    && [ "$(metadata_value target_release "$metadata")" = "$release_tag" ] \
    && [ "$(metadata_value target_commit "$metadata")" = "$release_commit" ] \
    && [ "$(metadata_value expected_migrations "$metadata")" = "$migrations" ] \
    && is_hex_sha256 "$(metadata_value compose_sha256 "$metadata")" \
    || { echo "PostgreSQL backup metadata does not match the prepared update" >&2; return 1; }
}

verify_companions_unchanged() {
  backup_dir=$1
  current=$(companion_signatures)
  expected=$(cat "$backup_dir/companion-containers.txt")
  if [ "$current" != "$expected" ]; then
    echo "Frontend, PostgreSQL, or Redis changed during backend deployment" >&2
    return 1
  fi
}

restore_image() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  data_backup_id=$5
  require_data_backup "$digest" "$release_tag" "$release_commit" "$migrations" "$data_backup_id" \
    || return 1
  prepared=$(prepared_dir "$digest")
  metadata=$prepared/metadata.env
  [ -r "$metadata" ] || return 1
  previous_image_ref=$(metadata_value previous_image_ref "$metadata") || return 1
  previous_image_id=$(metadata_value previous_image_id "$metadata") || return 1
  previous_version=$(metadata_value previous_version "$metadata") || return 1
  previous_commit=$(metadata_value previous_commit "$metadata") || return 1
  target_image_id=$(metadata_value target_image_id "$metadata") || return 1
  current_image_id=$(container_field "$BACKEND_CONTAINER" '{{.Image}}' 2>/dev/null || true)
  original_compose_sha=$(metadata_value compose_sha256 "$metadata") || return 1
  candidate_compose_sha=$(metadata_value candidate_compose_sha256 "$metadata") || return 1
  rollback_compose_sha=$(metadata_value rollback_compose_sha256 "$metadata") || return 1
  current_compose_sha=$(compose_sha256) || return 1

  if [ "$current_image_id" = "$previous_image_id" ] \
    && { [ "$current_compose_sha" = "$original_compose_sha" ] \
      || [ "$current_compose_sha" = "$rollback_compose_sha" ]; }; then
    verify_backend_health "$previous_image_id" "v$previous_version" "$previous_commit" \
      || return 1
    verify_companions_unchanged "$prepared" || return 1
    printf 'restore_state=already_previous\n'
    printf 'database_restore=not_performed\n'
    return
  fi

  if [ "$current_image_id" != "$previous_image_id" ] \
    && [ "$current_image_id" != "$target_image_id" ]; then
    echo "Refusing to restore a stale backup over an unrelated backend image" >&2
    return 1
  fi
  if [ "$current_image_id" = "$target_image_id" ] \
    && [ "$current_compose_sha" != "$candidate_compose_sha" ] \
    && [ "$current_compose_sha" != "$rollback_compose_sha" ]; then
    echo "Candidate Compose changed after deployment; refusing image restore" >&2
    return 1
  fi
  if [ "$current_image_id" = "$previous_image_id" ] \
    && [ "$current_compose_sha" != "$original_compose_sha" ] \
    && [ "$current_compose_sha" != "$rollback_compose_sha" ] \
    && [ "$current_compose_sha" != "$candidate_compose_sha" ]; then
    echo "Previous backend Compose drifted; refusing image restore" >&2
    return 1
  fi
  if [ ! -r "$DEPLOYMENT_STATE_FILE" ] \
    || [ "$(metadata_value digest "$DEPLOYMENT_STATE_FILE")" != "$digest" ] \
    || [ "$(metadata_value migrations "$DEPLOYMENT_STATE_FILE")" != "$migrations" ] \
    || [ "$(metadata_value data_backup_id "$DEPLOYMENT_STATE_FILE")" != "$data_backup_id" ]; then
    echo "Backend deployment state does not authorize this restore" >&2
    return 1
  fi
  [ "$(docker image inspect "$previous_image_ref" --format '{{.Id}}' 2>/dev/null || true)" = "$previous_image_id" ] \
    || { echo "The prepared previous backend image is no longer available" >&2; return 1; }

  restore_file=$(mktemp "$APP_DIR/.docker-compose.backend-restore.XXXXXX") \
    || return 1
  if ! cp "$prepared/rollback-compose.yml" "$restore_file" \
    || ! docker-compose -f "$restore_file" config -q; then
    rm -f -- "$restore_file"
    return 1
  fi
  if ! mv "$restore_file" "$COMPOSE_FILE"; then
    rm -f -- "$restore_file"
    return 1
  fi
  docker_compose up -d --no-deps --force-recreate sub2api || return 1
  verify_backend_health "$previous_image_id" "v$previous_version" "$previous_commit" \
    || return 1
  verify_companions_unchanged "$prepared" || return 1
  printf 'restored_previous_image=%s\n' "$previous_image_ref"
  printf 'rollback_health=healthy\n'
  printf 'database_restore=not_performed\n'
}

rollback_armed=false
active_digest=
active_release_tag=
active_release_commit=
active_migrations=
active_data_backup_id=

restore_interrupted_deploy() {
  status=$?
  [ "$status" -ne 0 ] || status=130
  trap - EXIT HUP INT TERM
  if [ "$rollback_armed" = "true" ]; then
    echo "Backend deployment exited unexpectedly; restoring the previous image" >&2
    if ! restore_image \
      "$active_digest" \
      "$active_release_tag" \
      "$active_release_commit" \
      "$active_migrations" \
      "$active_data_backup_id"; then
      echo "Interrupted deployment image restore failed; manual intervention is required" >&2
    fi
  fi
  exit "$status"
}

deploy_backend() {
  digest=$1
  release_tag=$2
  release_commit=$3
  migrations=$4
  data_backup_id=$5
  image=$(image_ref "$digest")
  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}' 2>/dev/null || true)" = "$image" ]; then
    expected_image_id=$(docker image inspect "$image" --format '{{.Id}}')
    verify_backend_health "$expected_image_id" "$release_tag" "$release_commit"
    verify_expected_migrations "$migrations"
    printf 'deploy_state=already_current\n'
    return
  fi
  require_prepared "$digest" "$release_tag" "$release_commit" "$migrations"
  require_data_backup "$digest" "$release_tag" "$release_commit" "$migrations" "$data_backup_id"
  prepared=$(prepared_dir "$digest")
  metadata=$prepared/metadata.env
  expected_image_id=$(docker image inspect "$image" --format '{{.Id}}')
  prepared_target_image_id=$(metadata_value target_image_id "$metadata") || return 1
  if [ "$expected_image_id" != "$prepared_target_image_id" ]; then
    echo "Target backend image changed after preparation" >&2
    return 1
  fi

  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Config.Image}}')" = "$image" ]; then
    verify_backend_health "$expected_image_id" "$release_tag" "$release_commit"
    verify_expected_migrations "$migrations"
    verify_companions_unchanged "$prepared"
    printf 'deploy_state=already_current\n'
    return
  fi

  previous_image_id=$(metadata_value previous_image_id "$metadata")
  original_compose_sha=$(metadata_value compose_sha256 "$metadata")
  if [ "$(container_field "$BACKEND_CONTAINER" '{{.Image}}')" != "$previous_image_id" ] \
    || [ "$(compose_sha256)" != "$original_compose_sha" ]; then
    echo "Production drifted after preparation; refusing backend deployment" >&2
    return 1
  fi

  candidate_file=$(mktemp "$APP_DIR/.docker-compose.backend-candidate.XXXXXX")
  cp "$prepared/candidate-compose.yml" "$candidate_file"
  docker-compose -f "$candidate_file" config -q
  write_deployment_state "$digest" "$migrations" "$data_backup_id"
  active_digest=$digest
  active_release_tag=$release_tag
  active_release_commit=$release_commit
  active_migrations=$migrations
  active_data_backup_id=$data_backup_id
  rollback_armed=true
  trap restore_interrupted_deploy EXIT HUP INT TERM
  mv "$candidate_file" "$COMPOSE_FILE"

  deploy_ok=true
  if ! docker_compose up -d --no-deps --force-recreate sub2api; then
    deploy_ok=false
  elif ! verify_backend_health "$expected_image_id" "$release_tag" "$release_commit"; then
    deploy_ok=false
  elif ! verify_expected_migrations "$migrations"; then
    deploy_ok=false
  elif ! verify_companions_unchanged "$prepared"; then
    deploy_ok=false
  fi

  if [ "$deploy_ok" != "true" ]; then
    echo "Backend deployment failed; restoring the verified previous image only" >&2
    if ! restore_image "$digest" "$release_tag" "$release_commit" "$migrations" "$data_backup_id"; then
      echo "Automatic backend image restore failed; manual intervention is required" >&2
    fi
    rollback_armed=false
    trap - EXIT HUP INT TERM
    if [ "$migrations" != "none" ]; then
      echo "The PostgreSQL backup was retained; database restore requires separate manual approval" >&2
    fi
    return 1
  fi

  rollback_armed=false
  active_digest=
  active_release_tag=
  active_release_commit=
  active_migrations=
  active_data_backup_id=
  trap - EXIT HUP INT TERM

  printf 'deployed_image=%s\n' "$image"
  printf 'deployed_release=%s\n' "$release_tag"
  printf 'deployed_commit=%s\n' "$release_commit"
  printf 'backend_health=healthy\n'
  printf 'companion_containers_unchanged=true\n'
}

if [ "${AIFOO_BACKEND_DEPLOY_LIBRARY_ONLY:-0}" != "1" ]; then
  require_root
  command=${1:-}
  case "$command" in
    preflight)
      if [ "${2:-}" = "prepared" ]; then
        prepared_backend_status "${3:-}" "${4:-}" "${5:-}" "${6:-}"
      else
        preflight_readonly "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-none}"
      fi
      ;;
    stage)
      acquire_mutation_lock
      prepare_backend "${2:-}" "${3:-}" "${4:-}" "${5:-none}"
      ;;
    prepare)
      acquire_mutation_lock
      prepare_backend "${2:-}" "${3:-}" "${4:-}" "${5:-}"
      ;;
    prepared-status)
      prepared_backend_status "${2:-}" "${3:-}" "${4:-}" "${5:-}"
      ;;
    backup-data)
      acquire_mutation_lock
      create_data_backup "${2:-}" "${3:-}" "${4:-}" "${5:-}"
      ;;
    backup)
      acquire_mutation_lock
      create_data_backup "${2:-}" "${3:-}" "${4:-}" "${5:-}"
      ;;
    deploy)
      acquire_mutation_lock
      deploy_backend "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
      ;;
    restore-image)
      acquire_mutation_lock
      restore_image "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
      ;;
    *)
      echo "Usage: $0 {preflight <helper-sha256> <digest> <release-tag> <release-commit> [migrations]|preflight prepared <digest> <release-tag> <release-commit> <migrations>|stage <digest> <release-tag> <release-commit> [migrations]|prepare <digest> <release-tag> <release-commit> <migrations>|prepared-status <digest> <release-tag> <release-commit> <migrations>|backup <digest> <release-tag> <release-commit> <migrations>|backup-data <digest> <release-tag> <release-commit> <migrations>|deploy <digest> <release-tag> <release-commit> <migrations> <data-backup-id>|restore-image <digest> <release-tag> <release-commit> <migrations> <data-backup-id>}" >&2
      exit 1
      ;;
  esac
fi
