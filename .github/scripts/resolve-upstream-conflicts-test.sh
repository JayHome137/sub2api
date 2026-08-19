#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
RESOLVER=$ROOT/.github/scripts/resolve-upstream-conflicts.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-conflict-resolver.XXXXXX")

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "conflict resolver test failed: $1" >&2
  exit 1
}

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" config user.name 'AIFoo conflict resolver test'
git -C "$TEST_ROOT" config user.email 'aifoo-conflict-resolver@example.invalid'
mkdir -p "$TEST_ROOT/.github/workflows" "$TEST_ROOT/backend/internal/ordinary"

printf '%s\n' 'shared=base' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'shared=base' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -qm base

git -C "$TEST_ROOT" checkout -qb ours
printf '%s\n' 'ui=ours' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'fork=ours' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -qm ours

git -C "$TEST_ROOT" checkout -qb theirs HEAD~1
printf '%s\n' 'ui=theirs' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'upstream=theirs' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -qm theirs

git -C "$TEST_ROOT" checkout -q ours
if git -C "$TEST_ROOT" merge --no-edit theirs >/dev/null 2>&1; then
  fail 'fixture did not create a merge conflict'
fi
mkdir -p "$TEST_ROOT/.github/scripts"
cp "$RESOLVER" "$TEST_ROOT/.github/scripts/resolve-upstream-conflicts.sh"
chmod +x "$TEST_ROOT/.github/scripts/resolve-upstream-conflicts.sh"

(cd "$TEST_ROOT" && .github/scripts/resolve-upstream-conflicts.sh)
[ -z "$(git -C "$TEST_ROOT" diff --name-only --diff-filter=U)" ] \
  || fail 'unresolved merge stages remain'
grep -Fxq 'ui=ours' "$TEST_ROOT/.github/workflows/policy.yml" \
  || fail 'fork delivery policy was not preserved'
grep -Fxq 'upstream=theirs' "$TEST_ROOT/backend/internal/ordinary/policy.go" \
  || fail 'ordinary upstream content was not selected'
if (cd "$TEST_ROOT" && .github/scripts/resolve-upstream-conflicts.sh >/dev/null 2>&1); then
  fail 'resolver accepted a non-merge state'
fi

echo 'conflict_resolver=ok'
