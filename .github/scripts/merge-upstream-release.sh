#!/bin/sh

# Merge one official release while keeping automation policy and overlapping
# presentation UI owned by the fork. Upstream workflow changes are audited,
# then removed before the merge commit so the default GITHUB_TOKEN never needs
# workflow write access.

set -eu

if [ "$#" -ne 4 ]; then
  echo 'usage: merge-upstream-release.sh RELEASE_REF BASE_REF RESOLVER AUDIT_FILE' >&2
  exit 2
fi

release_ref=$1
base_ref=$2
resolver=$3
workflow_audit=$4

if [ ! -x "$resolver" ]; then
  echo "Conflict resolver is not executable: $resolver" >&2
  exit 1
fi

base_commit=$(git rev-parse --verify "$base_ref^{commit}")
release_commit=$(git rev-parse --verify "$release_ref^{commit}")
common_base=$(git merge-base "$base_commit" "$release_commit")

fork_ui_changes=$(mktemp)
upstream_ui_changes=$(mktemp)
protected_ui_overlap=$(mktemp)
cleanup() {
  rm -f "$fork_ui_changes" "$upstream_ui_changes" "$protected_ui_overlap"
}
trap cleanup EXIT HUP INT TERM

if [ "$(git rev-parse HEAD)" != "$base_commit" ]; then
  echo 'Current checkout does not match the requested fork base' >&2
  exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Working tree is not clean before the release merge' >&2
  exit 1
fi

# Record official workflow changes since the last shared upstream commit.
# This remains evidence only; none of these paths enter the candidate tree.
: > "$workflow_audit"
git diff --name-status --find-renames \
  "$common_base" "$release_commit" -- .github/workflows > "$workflow_audit"

# A presentation file changed by both sides is not safe to combine hunk by
# hunk: Git can produce valid text with incomplete Vue state or imports. Keep
# the complete fork version for those overlaps. Upstream-only UI changes still
# enter the candidate, as do API, store, type, and dependency changes.
git diff --name-only --find-renames \
  "$common_base" "$base_commit" -- \
  frontend/src/views frontend/src/components frontend/src/styles \
  frontend/public frontend/src/main.ts \
  | LC_ALL=C sort -u > "$fork_ui_changes"
git diff --name-only --find-renames \
  "$common_base" "$release_commit" -- \
  frontend/src/views frontend/src/components frontend/src/styles \
  frontend/public frontend/src/main.ts \
  | LC_ALL=C sort -u > "$upstream_ui_changes"
comm -12 "$fork_ui_changes" "$upstream_ui_changes" > "$protected_ui_overlap"

if git diff --quiet "$common_base" "$release_commit" -- \
  .github/audit-exceptions.yml; then
  audit_exceptions_changed=false
else
  audit_exceptions_changed=true
fi

merge_conflicts=false
if ! git merge --no-commit --no-ff "$release_ref"; then
  merge_conflicts=true
  AIFOO_RESOLVER_NO_COMMIT=true "$resolver"
fi

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  echo 'Release merge did not leave an in-progress merge to commit' >&2
  exit 1
fi

# The complete workflow tree, including clean additions and deletions, is
# restored from the fork base. Conflict-only path policy is insufficient here.
git restore --source="$base_commit" --staged --worktree -- .github/workflows

# Security audit exceptions are also fork policy. A clean upstream edit or
# deletion must not silently remove a local exception or its documented scope.
git restore --source="$base_commit" --staged --worktree -- \
  .github/audit-exceptions.yml

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if git cat-file -e "$base_commit:$path" 2>/dev/null; then
    git restore --source="$base_commit" --staged --worktree -- "$path"
  else
    git rm -f --ignore-unmatch -- "$path" >/dev/null
  fi
  printf 'path=%s policy=fork-ui-complete mode=shared-base-overlap\n' "$path"
done < "$protected_ui_overlap"

if ! git diff --cached --quiet "$base_commit" -- \
  .github/workflows .github/audit-exceptions.yml; then
  echo 'Fork-owned automation policy differs from the production base' >&2
  exit 1
fi
if git ls-files --others --exclude-standard -- .github/workflows | grep -q .; then
  echo 'Untracked upstream workflow paths remain after normalization' >&2
  exit 1
fi

git diff --cached --check
git commit --no-edit

candidate_commit=$(git rev-parse HEAD)
git merge-base --is-ancestor "$base_commit" "$candidate_commit"
git merge-base --is-ancestor "$release_commit" "$candidate_commit"
if [ "$(git rev-parse HEAD^1)" != "$base_commit" ] \
  || [ "$(git rev-parse HEAD^2)" != "$release_commit" ]; then
  echo 'Release merge commit does not have the exact expected parents' >&2
  exit 1
fi

workflow_change_count=$(awk 'END { print NR + 0 }' "$workflow_audit")
protected_ui_overlap_count=$(awk 'END { print NR + 0 }' "$protected_ui_overlap")
printf 'merge_conflicts=%s\n' "$merge_conflicts"
printf 'fork_workflow_changes=%s\n' "$workflow_change_count"
printf 'fork_audit_exceptions_changed=%s\n' "$audit_exceptions_changed"
printf 'protected_ui_overlap=%s\n' "$protected_ui_overlap_count"
