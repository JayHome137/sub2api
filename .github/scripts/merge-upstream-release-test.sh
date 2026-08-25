#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
MERGER=$ROOT/.github/scripts/merge-upstream-release.sh
RESOLVER=$ROOT/.github/scripts/resolve-upstream-conflicts.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-upstream-merge.XXXXXX")

cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/aifoo-upstream-merge.*) rm -rf -- "$TEST_ROOT" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "upstream merge test failed: $1" >&2
  exit 1
}

init_repo() {
  repo=$1
  git -C "$repo" init -q
  git -C "$repo" config user.name 'AIFoo upstream merge test'
  git -C "$repo" config user.email 'aifoo-upstream-merge@example.invalid'
  mkdir -p \
    "$repo/.github/workflows" \
    "$repo/backend" \
    "$repo/frontend/public" \
    "$repo/frontend/src/api" \
    "$repo/frontend/src/components" \
    "$repo/frontend/src/views"
  printf '%s\n' 'owner=fork' > "$repo/.github/audit-exceptions.yml"
}

assert_merge_parents() {
  repo=$1
  expected_first=$2
  expected_second=$3
  [ "$(git -C "$repo" rev-parse HEAD^1)" = "$expected_first" ] \
    || fail 'candidate first parent is not the fork base'
  [ "$(git -C "$repo" rev-parse HEAD^2)" = "$expected_second" ] \
    || fail 'candidate second parent is not the official release'
}

clean_repo=$TEST_ROOT/clean
mkdir -p "$clean_repo"
init_repo "$clean_repo"
printf '%s\n' 'name: fork-base' > "$clean_repo/.github/workflows/base.yml"
printf '%s\n' 'name: retain-me' > "$clean_repo/.github/workflows/legacy.yml"
printf '%s\n' 'base' > "$clean_repo/backend/base.go"
printf '%s\n' \
  'header' 'fork-slot' \
  'shared-1' 'shared-2' 'shared-3' 'shared-4' \
  'shared-5' 'shared-6' 'shared-7' 'shared-8' \
  'upstream-slot' 'footer' \
  > "$clean_repo/frontend/src/views/HomeView.vue"
printf '%s\n' 'payment-base' \
  > "$clean_repo/frontend/src/views/PaymentResultView.vue"
printf '%s\n' \
  'fork-api-slot' \
  'api-shared-1' 'api-shared-2' 'api-shared-3' 'api-shared-4' \
  'api-shared-5' 'api-shared-6' 'api-shared-7' 'api-shared-8' \
  'upstream-api-slot' \
  > "$clean_repo/frontend/src/api/client.ts"
git -C "$clean_repo" add .
git -C "$clean_repo" commit -qm base

git -C "$clean_repo" checkout -qb fork
printf '%s\n' 'fork-only' > "$clean_repo/fork.txt"
sed -i.bak 's/fork-slot/fork-ui/' \
  "$clean_repo/frontend/src/views/HomeView.vue"
rm -f "$clean_repo/frontend/src/views/HomeView.vue.bak"
sed -i.bak 's/fork-api-slot/fork-api/' \
  "$clean_repo/frontend/src/api/client.ts"
rm -f "$clean_repo/frontend/src/api/client.ts.bak"
git -C "$clean_repo" add .
git -C "$clean_repo" commit -qm fork
clean_fork=$(git -C "$clean_repo" rev-parse HEAD)

git -C "$clean_repo" checkout -qb upstream HEAD~1
printf '%s\n' 'name: upstream-new' > "$clean_repo/.github/workflows/upstream.yml"
git -C "$clean_repo" rm -q .github/workflows/legacy.yml
git -C "$clean_repo" rm -q .github/audit-exceptions.yml
printf '%s\n' 'upstream-feature' > "$clean_repo/backend/upstream.go"
sed -i.bak 's/upstream-slot/upstream-ui/' \
  "$clean_repo/frontend/src/views/HomeView.vue"
rm -f "$clean_repo/frontend/src/views/HomeView.vue.bak"
printf '%s\n' 'payment-upstream' \
  > "$clean_repo/frontend/src/views/PaymentResultView.vue"
printf '%s\n' 'official-new-ui' \
  > "$clean_repo/frontend/src/components/OfficialNew.vue"
sed -i.bak 's/upstream-api-slot/upstream-api/' \
  "$clean_repo/frontend/src/api/client.ts"
rm -f "$clean_repo/frontend/src/api/client.ts.bak"
git -C "$clean_repo" add .
git -C "$clean_repo" commit -qm upstream
clean_release=$(git -C "$clean_repo" rev-parse HEAD)
git -C "$clean_repo" tag -a official-v1 -m 'official release v1'

git -C "$clean_repo" checkout -q fork
clean_audit=$TEST_ROOT/clean-audit.txt
clean_output=$TEST_ROOT/clean-output.txt
if (cd "$clean_repo" && "$MERGER" \
  official-v1 HEAD~1 "$RESOLVER" "$clean_audit") >/dev/null 2>&1; then
  fail 'merge helper accepted a checkout that did not match the fork base'
fi
printf '%s\n' 'dirty' > "$clean_repo/dirty.tmp"
if (cd "$clean_repo" && "$MERGER" \
  official-v1 "$clean_fork" "$RESOLVER" "$clean_audit") >/dev/null 2>&1; then
  fail 'merge helper accepted a dirty working tree'
fi
rm -f "$clean_repo/dirty.tmp"
(cd "$clean_repo" && "$MERGER" \
  official-v1 "$clean_fork" "$RESOLVER" "$clean_audit") > "$clean_output"

grep -Fxq 'merge_conflicts=false' "$clean_output" \
  || fail 'clean merge was reported as conflicted'
grep -Eq '^A[[:space:]]+\.github/workflows/upstream\.yml$' "$clean_audit" \
  || fail 'added upstream workflow was not audited'
grep -Eq '^D[[:space:]]+\.github/workflows/legacy\.yml$' "$clean_audit" \
  || fail 'deleted upstream workflow was not audited'
grep -Fxq 'fork_audit_exceptions_changed=true' "$clean_output" \
  || fail 'upstream audit-exception deletion was not reported'
grep -Fxq 'protected_ui_overlap=1' "$clean_output" \
  || fail 'shared protected UI change was not reported'
grep -Fq 'path=frontend/src/views/HomeView.vue policy=fork-ui-complete' \
  "$clean_output" \
  || fail 'shared protected UI decision was not logged'
git -C "$clean_repo" diff --quiet "$clean_fork" HEAD -- .github/workflows \
  || fail 'clean merge changed the fork workflow tree'
[ "$(cat "$clean_repo/.github/audit-exceptions.yml")" = 'owner=fork' ] \
  || fail 'clean upstream deletion changed fork audit exceptions'
[ ! -e "$clean_repo/.github/workflows/upstream.yml" ] \
  || fail 'new upstream workflow entered the candidate'
[ -f "$clean_repo/.github/workflows/legacy.yml" ] \
  || fail 'upstream workflow deletion changed the fork tree'
[ -f "$clean_repo/backend/upstream.go" ] \
  || fail 'ordinary upstream application content was discarded'
grep -Fxq 'fork-ui' "$clean_repo/frontend/src/views/HomeView.vue" \
  || fail 'shared protected UI did not retain the fork version'
if grep -Fq 'upstream-ui' "$clean_repo/frontend/src/views/HomeView.vue"; then
  fail 'shared protected UI retained an upstream semantic fragment'
fi
grep -Fxq 'payment-upstream' \
  "$clean_repo/frontend/src/views/PaymentResultView.vue" \
  || fail 'upstream-only protected UI change was discarded'
[ -f "$clean_repo/frontend/src/components/OfficialNew.vue" ] \
  || fail 'new official UI surface was discarded'
grep -Fxq 'fork-api' "$clean_repo/frontend/src/api/client.ts" \
  || fail 'fork API change was discarded'
grep -Fxq 'upstream-api' "$clean_repo/frontend/src/api/client.ts" \
  || fail 'upstream API change was incorrectly frozen'
assert_merge_parents "$clean_repo" "$clean_fork" "$clean_release"

conflict_repo=$TEST_ROOT/conflict
mkdir -p "$conflict_repo"
init_repo "$conflict_repo"
printf '%s\n' 'name: base' > "$conflict_repo/.github/workflows/policy.yml"
printf '%s\n' 'base' > "$conflict_repo/backend/base.go"
git -C "$conflict_repo" add .
git -C "$conflict_repo" commit -qm base

git -C "$conflict_repo" checkout -qb fork
printf '%s\n' 'name: fork' > "$conflict_repo/.github/workflows/policy.yml"
printf '%s\n' 'fork-only' > "$conflict_repo/fork.txt"
git -C "$conflict_repo" add .
git -C "$conflict_repo" commit -qm fork
conflict_fork=$(git -C "$conflict_repo" rev-parse HEAD)

git -C "$conflict_repo" checkout -qb upstream HEAD~1
printf '%s\n' 'name: upstream' > "$conflict_repo/.github/workflows/policy.yml"
printf '%s\n' 'owner=upstream' > "$conflict_repo/.github/audit-exceptions.yml"
printf '%s\n' 'upstream-feature' > "$conflict_repo/backend/upstream.go"
git -C "$conflict_repo" add .
git -C "$conflict_repo" commit -qm upstream
conflict_release=$(git -C "$conflict_repo" rev-parse HEAD)

git -C "$conflict_repo" checkout -q fork
conflict_audit=$TEST_ROOT/conflict-audit.txt
conflict_output=$TEST_ROOT/conflict-output.txt
(cd "$conflict_repo" && "$MERGER" \
  "$conflict_release" "$conflict_fork" "$RESOLVER" "$conflict_audit") \
  > "$conflict_output" 2>&1

grep -Fxq 'merge_conflicts=true' "$conflict_output" \
  || fail 'resolved workflow conflict was not reported'
grep -Eq '^M[[:space:]]+\.github/workflows/policy\.yml$' "$conflict_audit" \
  || fail 'conflicting upstream workflow was not audited'
grep -Fxq 'name: fork' "$conflict_repo/.github/workflows/policy.yml" \
  || fail 'conflicting workflow did not retain the complete fork version'
[ "$(cat "$conflict_repo/.github/audit-exceptions.yml")" = 'owner=fork' ] \
  || fail 'clean upstream edit changed fork audit exceptions'
git -C "$conflict_repo" diff --quiet "$conflict_fork" HEAD -- .github/workflows \
  || fail 'conflict merge changed the fork workflow tree'
[ -f "$conflict_repo/backend/upstream.go" ] \
  || fail 'conflict merge discarded ordinary upstream application content'
assert_merge_parents "$conflict_repo" "$conflict_fork" "$conflict_release"

echo 'upstream_merge=ok'
