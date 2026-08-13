#!/bin/sh

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
HELPER=$ROOT/deploy/control-plane/deploy-update-components.sh

fail() {
  echo "control-plane integration: $1" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

command -v openssl >/dev/null 2>&1 || fail 'openssl is required'
[ -s "$HELPER" ] || fail 'control-plane helper is missing'

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aifoo-control-plane-test.XXXXXX")
cleanup() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/aifoo-control-plane-test.*)
      rm -rf -- "$TEST_ROOT"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

key=$TEST_ROOT/private.pem
public_key=$TEST_ROOT/public.pem
payload_dir=$TEST_ROOT/payload
archive=$TEST_ROOT/payload.tar.gz
bad_archive=$TEST_ROOT/payload-extra.tar.gz
link_archive=$TEST_ROOT/payload-link.tar.gz
mkdir -p "$payload_dir"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key" >/dev/null 2>&1
openssl pkey -in "$key" -pubout -out "$public_key" >/dev/null
printf '%s\n' 'backend helper payload' > "$payload_dir/deploy-backend.sh"
printf '%s\n' 'update bridge payload' > "$payload_dir/aifoo-update-bridge"
helper_sha=$(sha256_file "$payload_dir/deploy-backend.sh")
bridge_sha=$(sha256_file "$payload_dir/aifoo-update-bridge")
{
  printf 'schema=1\n'
  printf 'backend_helper_sha256=%s\n' "$helper_sha"
  printf 'update_bridge_sha256=%s\n' "$bridge_sha"
} > "$payload_dir/manifest.env"
openssl dgst -sha256 -sign "$key" -out "$payload_dir/manifest.sig" "$payload_dir/manifest.env"
tar -C "$payload_dir" -czf "$archive" \
  deploy-backend.sh aifoo-update-bridge manifest.env manifest.sig

AIFOO_CONTROL_PLANE_LIBRARY_ONLY=1
export AIFOO_CONTROL_PLANE_LIBRARY_ONLY
. "$HELPER"

# The runtime helper requires root ownership. This isolated contract exercises
# archive membership and the signed-manifest verification boundary.
secure_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}
SIGNING_PUBLIC_KEY=$public_key

verify_archive_members "$archive"
verify_signed_manifest "$payload_dir" "$helper_sha" "$bridge_sha"

wrong_helper_sha=$(printf '%064d' 0 | tr '0' '0')
if (verify_signed_manifest "$payload_dir" "$wrong_helper_sha" "$bridge_sha"); then
  fail 'manifest accepted an unexpected helper checksum'
fi

printf '%s\n' 'unexpected member' > "$payload_dir/unexpected"
tar -C "$payload_dir" -czf "$bad_archive" \
  deploy-backend.sh aifoo-update-bridge manifest.env manifest.sig unexpected
if (verify_archive_members "$bad_archive"); then
  fail 'archive accepted an unexpected member'
fi

ln -s deploy-backend.sh "$payload_dir/linked-helper"
tar -C "$payload_dir" -czf "$link_archive" \
  deploy-backend.sh aifoo-update-bridge manifest.env manifest.sig linked-helper
if (require_no_symlink_members "$link_archive"); then
  fail 'archive accepted a symbolic link member'
fi
rm -f -- "$payload_dir/linked-helper"

printf '%s\n' '# tampered' >> "$payload_dir/manifest.env"
if (verify_signed_manifest "$payload_dir" "$helper_sha" "$bridge_sha"); then
  fail 'manifest accepted a tampered signature payload'
fi

echo 'control_plane_integration=ok'
