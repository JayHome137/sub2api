#!/bin/sh

# Resolve an in-progress upstream merge without replacing complete files.
# Only conflict hunks are selected; Git's non-conflicting merge result stays.
# Fork-owned UI and delivery files keep AIFoo's contract; all other conflicts
# take the official upstream hunk so the release can continue to validation.

set -eu

policy_for() {
  case "$1" in
    frontend/src/*|frontend/e2e/*|frontend/public/*|frontend/package.json|frontend/pnpm-lock.yaml|frontend/playwright.config.ts)
      # A conflict means this file already has fork-owned UI code. Keep that
      # contract; upstream-only new files merge normally without this branch.
      printf '%s\n' ours
      ;;
    .github/workflows/*|deploy/frontend/*|deploy/backend/*)
      # These are the fork's delivery contract. Upstream application commits
      # must not replace the preparation and one-click update gates.
      printf '%s\n' ours
      ;;
    *)
      printf '%s\n' theirs
      ;;
  esac
}

merge_head=$(git rev-parse -q --verify MERGE_HEAD 2>/dev/null || true)
if [ -z "$merge_head" ]; then
  echo 'No in-progress merge found; refusing to resolve an unrelated failure' >&2
  exit 1
fi

checkout_stage() {
  strategy=$1
  path=$2
  case "$strategy" in
    ours|ours-contract) git checkout --ours -- "$path" ;;
    theirs) git checkout --theirs -- "$path" ;;
    *) return 1 ;;
  esac
  git add -- "$path"
}

resolve_path() {
  path=$1
  policy=$(policy_for "$path")
  strategy=$policy

  base=$(mktemp)
  ours=$(mktemp)
  theirs=$(mktemp)
  cleanup() {
    rm -f "$base" "$ours" "$theirs"
  }
  trap cleanup EXIT HUP INT TERM

  if ! git show ":1:$path" > "$base" 2>/dev/null \
    || ! git show ":2:$path" > "$ours" 2>/dev/null \
    || ! git show ":3:$path" > "$theirs" 2>/dev/null; then
    checkout_stage "$strategy" "$path"
    printf 'path=%s policy=%s mode=stage-fallback\n' "$path" "$policy"
    trap - EXIT HUP INT TERM
    cleanup
    return 0
  fi

  resolved=$(mktemp)
  if ! git merge-file --"$strategy" -p "$ours" "$base" "$theirs" > "$resolved"; then
    rm -f "$resolved"
    trap - EXIT HUP INT TERM
    cleanup
    return 1
  fi
  mv "$resolved" "$path"
  git add -- "$path"
  printf 'path=%s policy=%s mode=conflict-hunks\n' "$path" "$policy"
  trap - EXIT HUP INT TERM
  cleanup
}

conflicted=$(git diff --name-only --diff-filter=U)
[ -n "$conflicted" ] || exit 0

printf '%s\n' "$conflicted" | while IFS= read -r path; do
  [ -n "$path" ] || continue
  resolve_path "$path"
done

if git diff --name-only --diff-filter=U | grep -q .; then
  echo 'Unresolved merge stages remain after deterministic conflict resolution' >&2
  exit 1
fi
if git grep -n -E '^(<<<<<<<|=======|>>>>>>>)( |$)' -- . >/dev/null 2>&1; then
  echo 'Conflict markers remain after deterministic conflict resolution' >&2
  exit 1
fi
git diff --check
git commit --no-edit
