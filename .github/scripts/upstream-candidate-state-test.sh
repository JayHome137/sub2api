#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
HELPER=$ROOT/.github/scripts/upstream-candidate-state.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-candidate-state.XXXXXX")

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/aifoo-candidate-state.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "upstream candidate state test failed: $1" >&2
  exit 1
}

repo=$TEST_ROOT/repo
mkdir -p "$repo/.github/workflows" "$repo/.github/scripts" "$repo/frontend"
git -C "$repo" init -q
git -C "$repo" config user.name 'AIFoo candidate state test'
git -C "$repo" config user.email 'aifoo-candidate-state@example.invalid'
printf '%s\n' 'name: fork workflow' > "$repo/.github/workflows/sync.yml"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$repo/.github/scripts/resolve-upstream-conflicts.sh"
printf '%s\n' 'base' > "$repo/frontend/app.ts"
git -C "$repo" add .
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)

git -C "$repo" checkout -qb release
printf '%s\n' 'official release' > "$repo/frontend/upstream.ts"
git -C "$repo" add .
git -C "$repo" commit -qm release
release=$(git -C "$repo" rev-parse HEAD)

git -C "$repo" checkout -qb candidate "$base"
git -C "$repo" merge --no-ff -qm 'merge release' "$release"
candidate=$(git -C "$repo" rev-parse HEAD)

reason=$(cd "$repo" && "$HELPER" refresh-reason "$base" "$release" "$candidate")
[ "$reason" = preserve ] || fail "unchanged candidate was not preserved: $reason"

printf '%s\n' 'repair' >> "$repo/frontend/app.ts"
git -C "$repo" add .
git -C "$repo" commit -qm repair
repair_candidate=$(git -C "$repo" rev-parse HEAD)
reason=$(cd "$repo" && "$HELPER" refresh-reason "$base" "$release" "$repair_candidate")
[ "$reason" = preserve ] || fail "repair commit was not preserved: $reason"

git -C "$repo" checkout -qb newer-production "$base"
printf '%s\n' 'new production' > "$repo/production.txt"
git -C "$repo" add .
git -C "$repo" commit -qm 'new production'
new_base=$(git -C "$repo" rev-parse HEAD)
reason=$(cd "$repo" && "$HELPER" refresh-reason "$new_base" "$release" "$repair_candidate")
[ "$reason" = production-base-changed ] \
  || fail "production change did not refresh the candidate: $reason"

git -C "$repo" checkout -q candidate
printf '%s\n' '# changed resolver' >> "$repo/.github/scripts/resolve-upstream-conflicts.sh"
git -C "$repo" add .
git -C "$repo" commit -qm 'change resolver'
resolver_candidate=$(git -C "$repo" rev-parse HEAD)
reason=$(cd "$repo" && "$HELPER" refresh-reason "$base" "$release" "$resolver_candidate")
[ "$reason" = resolver-changed ] \
  || fail "resolver drift did not refresh the candidate: $reason"

git -C "$repo" reset -q --hard "$repair_candidate"
printf '%s\n' 'name: changed workflow' > "$repo/.github/workflows/sync.yml"
git -C "$repo" add .
git -C "$repo" commit -qm 'change workflow contract'
workflow_candidate=$(git -C "$repo" rev-parse HEAD)
reason=$(cd "$repo" && "$HELPER" refresh-reason "$base" "$release" "$workflow_candidate")
[ "$reason" = workflow-contract-changed ] \
  || fail "workflow drift did not refresh the candidate: $reason"

candidate_tree=$(cd "$repo" && "$HELPER" candidate-tree-sha "$repair_candidate")
resolver_sha=$(cd "$repo" && "$HELPER" resolver-sha "$base")
workflow_sha=$(cd "$repo" && "$HELPER" workflow-contract-sha "$base")
fingerprint=$(cd "$repo" && "$HELPER" fingerprint \
  "$base" "$release" "$repair_candidate" "$candidate_tree" "$resolver_sha" "$workflow_sha")
initial_tree=$(cd "$repo" && "$HELPER" candidate-tree-sha "$candidate")
initial_fingerprint=$(cd "$repo" && "$HELPER" fingerprint \
  "$base" "$release" "$candidate" "$initial_tree" "$resolver_sha" "$workflow_sha")
case "$fingerprint" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail 'fingerprint is not hexadecimal' ;;
esac
[ "${#fingerprint}" -eq 64 ] || fail 'fingerprint is not SHA-256'

statuses=$TEST_ROOT/statuses.json
cat > "$statuses" <<EOF
[
  {"id":1,"context":"aifoo/candidate-ci","description":"fingerprint:$initial_fingerprint","state":"failure","created_at":"2026-08-25T00:00:00Z"},
  {"id":2,"context":"aifoo/candidate-ci","description":"fingerprint:$initial_fingerprint","state":"success","created_at":"2026-08-25T00:01:00Z"}
]
EOF
(cd "$repo" && "$HELPER" status-reusable aifoo/candidate-ci "$initial_fingerprint" "$statuses") \
  || fail 'latest successful stage status was not reused'
[ "$(cd "$repo" && "$HELPER" status-state aifoo/candidate-ci "$initial_fingerprint" "$statuses")" = success ] \
  || fail 'latest matching stage state was not returned'
if (cd "$repo" && "$HELPER" status-reusable aifoo/candidate-ci "$fingerprint" "$statuses"); then
  fail 'a repair commit with a new SHA reused stale stage evidence'
fi
[ "$(cd "$repo" && "$HELPER" status-state aifoo/candidate-ci "$fingerprint" "$statuses")" = missing ] \
  || fail 'a new candidate SHA inherited an old stage state'

echo 'upstream_candidate_state=ok'
