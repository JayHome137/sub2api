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
mkdir -p "$TEST_ROOT/.github/workflows" "$TEST_ROOT/backend/internal/ordinary" "$TEST_ROOT/frontend/src"

printf '%s\n' 'shared=base' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'shared=base' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
printf '%s\n' 'delete=base' > "$TEST_ROOT/frontend/src/delete-modify.ts"
printf '%s\n' 'delete=base' > "$TEST_ROOT/backend/internal/ordinary/modify-delete.go"
printf '%s\n' \
  'conflict=base' \
  'separator-1' \
  'separator-2' \
  'separator-3' \
  'separator-4' \
  'ours_only=base' \
  'separator-5' \
  'separator-6' \
  'separator-7' \
  'separator-8' \
  'theirs_only=base' > "$TEST_ROOT/frontend/src/normal-text.ts"
printf '%s\n' 'rename=base' > "$TEST_ROOT/frontend/src/rename-source.ts"
printf '\000base' > "$TEST_ROOT/backend/internal/ordinary/binary.bin"
printf '%s\n' 'vite=base' > "$TEST_ROOT/frontend/vite.config.ts"
printf '%s\n' 'tsconfig=base' > "$TEST_ROOT/frontend/tsconfig.json"
printf '%s\n' 'future=base' > "$TEST_ROOT/frontend/future-tool.config.ts"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -qm base

git -C "$TEST_ROOT" checkout -qb ours
printf '%s\n' 'ui=ours' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'fork=ours' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
git -C "$TEST_ROOT" rm -q frontend/src/delete-modify.ts
printf '%s\n' 'modify=ours' > "$TEST_ROOT/backend/internal/ordinary/modify-delete.go"
printf '%s\n' \
  'conflict=ours' \
  'separator-1' \
  'separator-2' \
  'separator-3' \
  'separator-4' \
  'ours_only=ours' \
  'separator-5' \
  'separator-6' \
  'separator-7' \
  'separator-8' \
  'theirs_only=base' > "$TEST_ROOT/frontend/src/normal-text.ts"
printf '%s\n' 'add=ours' > "$TEST_ROOT/frontend/src/add-add.ts"
git -C "$TEST_ROOT" mv frontend/src/rename-source.ts frontend/src/rename-kept.ts
printf '\000ours' > "$TEST_ROOT/backend/internal/ordinary/binary.bin"
printf '%s\n' 'vite=ours' > "$TEST_ROOT/frontend/vite.config.ts"
printf '%s\n' 'tsconfig=ours' > "$TEST_ROOT/frontend/tsconfig.json"
printf '%s\n' 'future=ours' > "$TEST_ROOT/frontend/future-tool.config.ts"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -qm ours

git -C "$TEST_ROOT" checkout -qb theirs HEAD~1
printf '%s\n' 'ui=theirs' > "$TEST_ROOT/.github/workflows/policy.yml"
printf '%s\n' 'upstream=theirs' > "$TEST_ROOT/backend/internal/ordinary/policy.go"
printf '%s\n' 'delete=theirs' > "$TEST_ROOT/frontend/src/delete-modify.ts"
git -C "$TEST_ROOT" rm -q backend/internal/ordinary/modify-delete.go
printf '%s\n' \
  'conflict=theirs' \
  'separator-1' \
  'separator-2' \
  'separator-3' \
  'separator-4' \
  'ours_only=base' \
  'separator-5' \
  'separator-6' \
  'separator-7' \
  'separator-8' \
  'theirs_only=theirs' > "$TEST_ROOT/frontend/src/normal-text.ts"
printf '%s\n' 'add=theirs' > "$TEST_ROOT/frontend/src/add-add.ts"
git -C "$TEST_ROOT" rm -q frontend/src/rename-source.ts
printf '\000theirs' > "$TEST_ROOT/backend/internal/ordinary/binary.bin"
printf '%s\n' 'vite=theirs' > "$TEST_ROOT/frontend/vite.config.ts"
printf '%s\n' 'tsconfig=theirs' > "$TEST_ROOT/frontend/tsconfig.json"
printf '%s\n' 'future=theirs' > "$TEST_ROOT/frontend/future-tool.config.ts"
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
grep -Fxq 'conflict=ours' "$TEST_ROOT/frontend/src/normal-text.ts" \
  || fail 'text conflict hunk did not retain the fork policy side'
grep -Fxq 'ours_only=ours' "$TEST_ROOT/frontend/src/normal-text.ts" \
  || fail 'text merge discarded an ours-only non-conflicting hunk'
grep -Fxq 'theirs_only=theirs' "$TEST_ROOT/frontend/src/normal-text.ts" \
  || fail 'text merge discarded a theirs-only non-conflicting hunk'
[ ! -e "$TEST_ROOT/frontend/src/delete-modify.ts" ] \
  || fail 'ours-side deletion was not staged for delete/modify conflict'
[ ! -e "$TEST_ROOT/backend/internal/ordinary/modify-delete.go" ] \
  || fail 'theirs-side deletion was not staged for modify/delete conflict'
grep -Fxq 'add=ours' "$TEST_ROOT/frontend/src/add-add.ts" \
  || fail 'ours policy was not selected for add/add conflict'
[ -f "$TEST_ROOT/frontend/src/rename-kept.ts" ] \
  || fail 'ours-side rename was not retained for rename/delete conflict'
[ ! -e "$TEST_ROOT/frontend/src/rename-source.ts" ] \
  || fail 'rename/delete conflict restored the removed source path'
git -C "$TEST_ROOT" show theirs:backend/internal/ordinary/binary.bin > "$TEST_ROOT/expected-theirs.bin"
cmp -s "$TEST_ROOT/expected-theirs.bin" "$TEST_ROOT/backend/internal/ordinary/binary.bin" \
  || fail 'binary conflict did not select the explicit upstream policy side'
grep -Fxq 'vite=ours' "$TEST_ROOT/frontend/vite.config.ts" \
  || fail 'frontend root build configuration was not protected'
grep -Fxq 'tsconfig=ours' "$TEST_ROOT/frontend/tsconfig.json" \
  || fail 'frontend root TypeScript configuration was not protected'
grep -Fxq 'future=ours' "$TEST_ROOT/frontend/future-tool.config.ts" \
  || fail 'future frontend root configuration was not protected'
if (cd "$TEST_ROOT" && .github/scripts/resolve-upstream-conflicts.sh >/dev/null 2>&1); then
  fail 'resolver accepted a non-merge state and faked success'
fi

echo 'conflict_resolver=ok'
