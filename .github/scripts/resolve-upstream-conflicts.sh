#!/bin/sh

# Resolve an in-progress upstream merge without replacing complete files.
# Only conflict hunks are selected; Git's non-conflicting merge result stays.
# Fork-owned UI and delivery files keep AIFoo's contract; all other conflicts
# take the official upstream hunk so the release can continue to validation.

set -eu

policy_for() {
  case "$1" in
    frontend/*)
      # A conflict means this file already has fork-owned UI or build code.
      # Keep that contract; upstream-only new files merge normally without
      # entering this conflict branch.
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

stage_exists() {
  stage=$1
  path=$2
  git ls-files -u -- "$path" | awk -v stage="$stage" '
    $3 == stage { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

checkout_stage() {
  strategy=$1
  path=$2
  reason=${3:-missing-stage}
  stage=
  case "$strategy" in
    ours|ours-contract) stage=2 ;;
    theirs) stage=3 ;;
    *)
      echo "Unknown conflict policy '$strategy' for $path" >&2
      return 1
      ;;
  esac

  if stage_exists "$stage" "$path"; then
    case "$strategy" in
      ours|ours-contract) git checkout --ours -- "$path" ;;
      theirs) git checkout --theirs -- "$path" ;;
    esac
    git add -- "$path"
    printf 'path=%s policy=%s mode=stage-fallback reason=%s action=checkout-stage-%s\n' "$path" "$strategy" "$reason" "$stage"
    return 0
  fi

  # In delete/modify and rename/delete conflicts, the selected side has no
  # stage. That is an intentional deletion, not a failed checkout.
  if ! git ls-files -u -- "$path" | grep -q .; then
    echo "No merge stages found while resolving $path" >&2
    return 1
  fi
  git rm -f -- "$path"
  printf 'path=%s policy=%s mode=stage-fallback reason=%s action=stage-delete\n' "$path" "$strategy" "$reason"
}

is_binary_pair() {
  git diff --no-index --numstat -- "$1" "$2" 2>/dev/null | awk '
    $1 == "-" && $2 == "-" { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

is_binary_conflict() {
  is_binary_pair "$1" "$2" \
    || is_binary_pair "$1" "$3" \
    || is_binary_pair "$2" "$3"
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

  # Add/add and delete/modify conflicts intentionally lack one or more merge
  # stages. Select the policy side when present; otherwise stage the deletion.
  if ! stage_exists 1 "$path" \
    || ! stage_exists 2 "$path" \
    || ! stage_exists 3 "$path"; then
    checkout_stage "$strategy" "$path"
    trap - EXIT HUP INT TERM
    cleanup
    return 0
  fi

  if ! git show ":1:$path" > "$base" 2>/dev/null \
    || ! git show ":2:$path" > "$ours" 2>/dev/null \
    || ! git show ":3:$path" > "$theirs" 2>/dev/null; then
    echo "Unable to materialize merge stages for $path" >&2
    trap - EXIT HUP INT TERM
    cleanup
    return 1
  fi

  if is_binary_conflict "$base" "$ours" "$theirs"; then
    checkout_stage "$strategy" "$path" binary
    trap - EXIT HUP INT TERM
    cleanup
    return 0
  fi

  resolved=$(mktemp)
  if git merge-file --"$strategy" -p "$ours" "$base" "$theirs" > "$resolved"; then
    mv "$resolved" "$path"
    git add -- "$path"
    printf 'path=%s policy=%s mode=conflict-hunks\n' "$path" "$policy"
  else
    # git merge-file rejects binary content. It can also reject another
    # unmergeable representation; in either case the explicit path policy is
    # safer than leaving a U state or manufacturing a text merge.
    rm -f "$resolved"
    checkout_stage "$strategy" "$path" unmergeable
  fi
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
