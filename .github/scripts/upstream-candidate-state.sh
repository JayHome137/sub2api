#!/bin/sh

# Pure helpers for deciding whether an upstream candidate can be resumed.
# The workflow owns network mutations; this script only inspects Git objects
# and previously downloaded commit-status JSON.

set -eu

fail() {
  echo "upstream candidate state: $1" >&2
  exit 1
}

require_commit() {
  git rev-parse --verify "$1^{commit}" >/dev/null 2>&1 \
    || fail "commit does not exist: $1"
}

candidate_tree_sha() {
  require_commit "$1"
  git rev-parse "$1^{tree}"
}

resolver_sha() {
  require_commit "$1"
  git rev-parse "$1:.github/scripts/resolve-upstream-conflicts.sh" 2>/dev/null \
    || fail "resolver is missing from $1"
}

workflow_contract_sha() {
  require_commit "$1"
  listing=$(git ls-tree -r "$1" -- \
    .github/workflows \
    .github/scripts/merge-upstream-release.sh \
    .github/scripts/merge-upstream-release-test.sh \
    .github/scripts/resolve-upstream-conflicts-test.sh \
    .github/scripts/upstream-candidate-state.sh \
    .github/scripts/upstream-candidate-state-test.sh \
    deploy/frontend/workflow-contract-test.sh \
    deploy/backend/workflow-contract-test.sh \
    AIFOO_UI_BOUNDARY.md)
  [ -n "$listing" ] || fail "workflow contract is missing from $1"
  printf '%s\n' "$listing" | LC_ALL=C sort | git hash-object --stdin
}

release_base_sha() {
  release=$1
  candidate=$2
  require_commit "$release"
  require_commit "$candidate"
  git rev-list --parents "$candidate" \
    | awk -v release="$release" '
        NF == 3 && $3 == release { print $2; exit }
      '
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    fail 'no SHA-256 implementation is available'
  fi
}

fingerprint() {
  [ "$#" -eq 6 ] || fail 'fingerprint requires six SHA values'
  printf '%s\n' \
    "base_sha=$1" \
    "release_commit=$2" \
    "candidate_sha=$3" \
    "candidate_tree_sha=$4" \
    "resolver_sha=$5" \
    "workflow_contract_sha=$6" \
    | hash_stdin
}

refresh_reason() {
  [ "$#" -eq 3 ] || fail 'refresh-reason requires BASE RELEASE CANDIDATE'
  base=$1
  release=$2
  candidate=$3
  require_commit "$base"
  require_commit "$release"
  require_commit "$candidate"

  recorded_base=$(release_base_sha "$release" "$candidate")
  if [ -z "$recorded_base" ]; then
    echo official-release-changed
    return 0
  fi
  if [ "$recorded_base" != "$(git rev-parse "$base^{commit}")" ]; then
    echo production-base-changed
    return 0
  fi
  if ! git merge-base --is-ancestor "$release" "$candidate"; then
    echo official-release-changed
    return 0
  fi
  if ! git merge-base --is-ancestor "$base" "$candidate"; then
    echo candidate-invalid
    return 0
  fi
  if [ "$(resolver_sha "$base")" != "$(resolver_sha "$candidate")" ]; then
    echo resolver-changed
    return 0
  fi
  if [ "$(workflow_contract_sha "$base")" != "$(workflow_contract_sha "$candidate")" ]; then
    echo workflow-contract-changed
    return 0
  fi
  echo preserve
}

status_reusable() {
  [ "$#" -eq 3 ] || fail 'status-reusable requires CONTEXT FINGERPRINT JSON_FILE'
  context=$1
  expected_fingerprint=$2
  statuses_file=$3
  [ -s "$statuses_file" ] || exit 1
  jq -e \
    --arg context "$context" \
    --arg description "fingerprint:$expected_fingerprint" '
      map(select(.context == $context and .description == $description))
      | sort_by(.created_at, .id)
      | last
      | .state == "success"
    ' "$statuses_file" >/dev/null
}

status_state() {
  [ "$#" -eq 3 ] || fail 'status-state requires CONTEXT FINGERPRINT JSON_FILE'
  context=$1
  expected_fingerprint=$2
  statuses_file=$3
  [ -s "$statuses_file" ] || {
    echo missing
    return 0
  }
  state=$(jq -r \
    --arg context "$context" \
    --arg description "fingerprint:$expected_fingerprint" '
      map(select(.context == $context and .description == $description))
      | sort_by(.created_at, .id)
      | last
      | .state // "missing"
    ' "$statuses_file")
  echo "$state"
}

command=${1:-}
case "$command" in
  candidate-tree-sha)
    [ "$#" -eq 2 ] || fail 'candidate-tree-sha requires REF'
    candidate_tree_sha "$2"
    ;;
  resolver-sha)
    [ "$#" -eq 2 ] || fail 'resolver-sha requires REF'
    resolver_sha "$2"
    ;;
  workflow-contract-sha)
    [ "$#" -eq 2 ] || fail 'workflow-contract-sha requires REF'
    workflow_contract_sha "$2"
    ;;
  release-base-sha)
    [ "$#" -eq 3 ] || fail 'release-base-sha requires RELEASE CANDIDATE'
    release_base_sha "$2" "$3"
    ;;
  fingerprint)
    shift
    fingerprint "$@"
    ;;
  refresh-reason)
    [ "$#" -eq 4 ] || fail 'refresh-reason requires BASE RELEASE CANDIDATE'
    refresh_reason "$2" "$3" "$4"
    ;;
  status-reusable)
    [ "$#" -eq 4 ] || fail 'status-reusable requires CONTEXT FINGERPRINT JSON_FILE'
    status_reusable "$2" "$3" "$4"
    ;;
  status-state)
    [ "$#" -eq 4 ] || fail 'status-state requires CONTEXT FINGERPRINT JSON_FILE'
    status_state "$2" "$3" "$4"
    ;;
  *)
    fail 'expected candidate-tree-sha, resolver-sha, workflow-contract-sha, release-base-sha, fingerprint, refresh-reason, status-reusable, or status-state'
    ;;
esac
