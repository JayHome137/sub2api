#!/bin/sh

set -eu

TARGET_IMAGE=${1:-}
TARGET_RELEASE=${2:-}
TARGET_COMMIT=${3:-}
EXPECTED_MIGRATIONS=${4:-none}
CURRENT_IMAGE=${5:-}
CURRENT_RELEASE=${6:-}
CURRENT_COMMIT=${7:-}
POSTGRES_IMAGE=postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
REDIS_IMAGE=redis:7-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2

validate_image() {
  if ! printf '%s' "$1" \
    | grep -Eq '^weishaw/sub2api@sha256:[0-9a-f]{64}$'; then
    echo "Expected an immutable official backend image" >&2
    exit 1
  fi
}

validate_release() {
  if ! printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Expected a stable vX.Y.Z release tag" >&2
    exit 1
  fi
}

validate_commit() {
  if ! printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "Expected an official release commit" >&2
    exit 1
  fi
}

validate_image "$TARGET_IMAGE"
validate_release "$TARGET_RELEASE"
validate_commit "$TARGET_COMMIT"
validate_image "$CURRENT_IMAGE"
validate_release "$CURRENT_RELEASE"
validate_commit "$CURRENT_COMMIT"
if [ "$EXPECTED_MIGRATIONS" != "none" ] \
  && ! printf '%s' "$EXPECTED_MIGRATIONS" \
    | grep -Eq '^[0-9]{3}_[a-z0-9_]+(_notx)?\.sql(,[0-9]{3}_[a-z0-9_]+(_notx)?\.sql)*$'; then
  echo "Expected none or comma-separated migration filenames" >&2
  exit 1
fi

test_id=$(printf '%s-%s' "${GITHUB_RUN_ID:-$$}" "${GITHUB_RUN_ATTEMPT:-1}" \
  | tr -cd 'A-Za-z0-9-')
network=aifoo-backend-test-$test_id
postgres=aifoo-backend-postgres-$test_id
redis=aifoo-backend-redis-$test_id
baseline=aifoo-backend-baseline-$test_id
candidate=aifoo-backend-candidate-$test_id
rollback=aifoo-backend-rollback-$test_id
label=cc.aifoo.test=backend-image-$test_id

cleanup() {
  docker container rm -f \
    "$baseline" "$candidate" "$rollback" "$postgres" "$redis" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

verify_official_image() {
  image=$1
  release=$2
  commit=$3
  tagged_image=weishaw/sub2api:${release#v}
  docker pull "$tagged_image" >/dev/null
  docker pull "$image" >/dev/null
  if ! docker image inspect "$tagged_image" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -Fxq "$image"; then
    echo "Official release tag does not resolve to the requested immutable image" >&2
    exit 1
  fi
  source_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
  revision_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
  version_label=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
  if [ "$source_label" != "https://github.com/Wei-Shaw/sub2api" ] \
    || [ "$revision_label" != "$commit" ] \
    || [ "$version_label" != "${release#v}" ]; then
    echo "Official image labels do not match the requested release" >&2
    exit 1
  fi

  version_output=$(docker run --rm --network none --entrypoint /app/sub2api \
    "$image" --version 2>&1)
  actual_version=$(printf '%s\n' "$version_output" \
    | grep -oE 'Sub2API v?[0-9]+\.[0-9]+\.[0-9]+' \
    | tail -n 1 | awk '{sub(/^v/, "", $2); print $2}')
  actual_commit=$(printf '%s\n' "$version_output" \
    | grep -oE 'commit: [0-9a-f]{40}' | tail -n 1 | awk '{print $2}')
  if [ "$actual_version" != "${release#v}" ] || [ "$actual_commit" != "$commit" ]; then
    echo "Official image version output does not match the requested release" >&2
    exit 1
  fi
}

start_backend() {
  name=$1
  image=$2
  docker run -d \
    --name "$name" \
    --label "$label" \
    --network "$network" \
    -e AUTO_SETUP=true \
    -e SERVER_HOST=0.0.0.0 \
    -e SERVER_PORT=8080 \
    -e DATABASE_HOST="$postgres" \
    -e DATABASE_PORT=5432 \
    -e DATABASE_USER=sub2api \
    -e DATABASE_PASSWORD=aifoo-ci-backend-only \
    -e DATABASE_DBNAME=sub2api \
    -e DATABASE_SSLMODE=disable \
    -e REDIS_HOST="$redis" \
    -e REDIS_PORT=6379 \
    -e ADMIN_EMAIL=ci-backend@sub2api.invalid \
    -e ADMIN_PASSWORD=AIFoo-CI-Backend-Only-2026 \
    -e JWT_SECRET=aifoo-ci-jwt-secret-not-for-production \
    -e TOTP_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    "$image" >/dev/null
}

wait_backend() {
  name=$1
  release=$2
  commit=$3
  attempts=0
  while [ "$attempts" -lt 90 ]; do
    state=$(docker inspect "$name" --format '{{.State.Status}}')
    if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
      docker logs --tail 120 "$name" >&2 || true
      echo "Official backend image exited during isolated startup" >&2
      return 1
    fi
    if docker exec "$name" wget -q -T 5 -O - http://127.0.0.1:8080/health \
      | grep -q '"status":"ok"'; then
      running_output=$(docker exec "$name" /app/sub2api --version 2>&1)
      running_version=$(printf '%s\n' "$running_output" \
        | grep -oE 'Sub2API v?[0-9]+\.[0-9]+\.[0-9]+' \
        | tail -n 1 | awk '{sub(/^v/, "", $2); print $2}')
      running_commit=$(printf '%s\n' "$running_output" \
        | grep -oE 'commit: [0-9a-f]{40}' | tail -n 1 | awk '{print $2}')
      if [ "$running_version" = "${release#v}" ] && [ "$running_commit" = "$commit" ]; then
        return 0
      fi
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  docker logs --tail 120 "$name" >&2 || true
  echo "Official backend image failed the isolated health or provenance check" >&2
  return 1
}

verify_official_image "$CURRENT_IMAGE" "$CURRENT_RELEASE" "$CURRENT_COMMIT"
verify_official_image "$TARGET_IMAGE" "$TARGET_RELEASE" "$TARGET_COMMIT"

docker network create --label "$label" "$network" >/dev/null
docker run -d \
  --name "$postgres" \
  --label "$label" \
  --network "$network" \
  -e POSTGRES_USER=sub2api \
  -e POSTGRES_PASSWORD=aifoo-ci-backend-only \
  -e POSTGRES_DB=sub2api \
  "$POSTGRES_IMAGE" >/dev/null
docker run -d \
  --name "$redis" \
  --label "$label" \
  --network "$network" \
  "$REDIS_IMAGE" >/dev/null

attempt=0
while [ "$attempt" -lt 60 ]; do
  if docker exec "$postgres" pg_isready -U sub2api -d sub2api >/dev/null 2>&1 \
    && [ "$(docker exec "$redis" redis-cli ping 2>/dev/null)" = "PONG" ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -ge 60 ]; then
  echo "Isolated PostgreSQL or Redis did not become ready" >&2
  exit 1
fi

# Build a baseline with the exact production image before applying target migrations.
start_backend "$baseline" "$CURRENT_IMAGE"
wait_backend "$baseline" "$CURRENT_RELEASE" "$CURRENT_COMMIT"
docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api \
  -c 'CREATE TABLE aifoo_ci_backend_rollback_probe (id integer PRIMARY KEY, value text NOT NULL);' \
  -c "INSERT INTO aifoo_ci_backend_rollback_probe VALUES (1, 'preserved');" >/dev/null
docker exec "$redis" redis-cli SET aifoo:ci:backend-rollback-probe preserved >/dev/null
docker container rm -f "$baseline" >/dev/null

# Apply the target release to the existing schema, as production would.
start_backend "$candidate" "$TARGET_IMAGE"
wait_backend "$candidate" "$TARGET_RELEASE" "$TARGET_COMMIT"
if [ "$EXPECTED_MIGRATIONS" = "none" ]; then
  docker exec "$postgres" psql -At -U sub2api -d sub2api \
    -c 'SELECT COUNT(*) FROM schema_migrations;' | grep -Eq '^[1-9][0-9]*$'
else
  old_ifs=$IFS
  IFS=,
  for migration in $EXPECTED_MIGRATIONS; do
    count=$(docker exec "$postgres" psql -At -U sub2api -d sub2api \
      -v ON_ERROR_STOP=1 \
      -c "SELECT COUNT(*) FROM schema_migrations WHERE filename = '$migration';")
    if [ "$count" != "1" ]; then
      echo "Isolated image did not apply migration: $migration" >&2
      IFS=$old_ifs
      exit 1
    fi
  done
  IFS=$old_ifs
fi
target_migration_count=$(docker exec "$postgres" psql -At -U sub2api -d sub2api \
  -c 'SELECT COUNT(*) FROM schema_migrations;')
docker container rm -f "$candidate" >/dev/null

# Prove that image-only rollback can run on the schema left by the target image.
start_backend "$rollback" "$CURRENT_IMAGE"
wait_backend "$rollback" "$CURRENT_RELEASE" "$CURRENT_COMMIT"
rollback_migration_count=$(docker exec "$postgres" psql -At -U sub2api -d sub2api \
  -c 'SELECT COUNT(*) FROM schema_migrations;')
if [ "$rollback_migration_count" != "$target_migration_count" ]; then
  echo "The rollback image changed the target migration state" >&2
  exit 1
fi
probe_value=$(docker exec "$postgres" psql -At -U sub2api -d sub2api \
  -c 'SELECT value FROM aifoo_ci_backend_rollback_probe WHERE id = 1;')
redis_probe=$(docker exec "$redis" redis-cli GET aifoo:ci:backend-rollback-probe)
if [ "$probe_value" != "preserved" ] || [ "$redis_probe" != "preserved" ]; then
  echo "The isolated upgrade or image rollback lost the storage probe" >&2
  exit 1
fi

printf 'official_backend_image=%s\n' "$TARGET_IMAGE"
printf 'official_backend_release=%s\n' "$TARGET_RELEASE"
printf 'official_backend_commit=%s\n' "$TARGET_COMMIT"
printf 'production_baseline_image=%s\n' "$CURRENT_IMAGE"
printf 'production_baseline_release=%s\n' "$CURRENT_RELEASE"
printf 'production_baseline_commit=%s\n' "$CURRENT_COMMIT"
printf 'isolated_database_migrations=verified\n'
printf 'image_only_rollback_compatibility=verified\n'
printf 'backend_image_integration=ok\n'
