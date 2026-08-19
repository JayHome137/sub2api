#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
script="$repo_root/deploy/docker-deploy.sh"

fail() {
  printf 'docker deploy security test failed: %s\n' "$1" >&2
  exit 1
}

[ -s "$script" ] || fail 'deployment script is missing'

# Downloads must fail closed instead of treating an HTTP error page as config.
grep -Fq 'curl --fail --location' "$script" || fail 'curl download is not fail-closed'
grep -Fq 'wget --quiet --tries=3' "$script" || fail 'wget download retry policy is missing'
grep -Fq 'Downloaded file is empty' "$script" || fail 'empty download check is missing'

# Generated credentials may be written to the owner-only .env file, never to logs.
if grep -Eq '^[[:space:]]*(echo|printf|print_(info|success|warning)).*(POSTGRES_PASSWORD|JWT_SECRET|TOTP_ENCRYPTION_KEY).*\$\{' "$script"; then
  fail 'generated credential is printed to the terminal'
fi

printf 'docker deploy security test passed\n'
