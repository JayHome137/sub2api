#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_FUNCTIONS="$TEST_DIR/install-functions.sh"
awk '/^calculate_sha256\(\) \{/,/^}/; /^download_and_extract\(\) \{/,/^}/' \
    "$ROOT_DIR/deploy/install.sh" > "$INSTALL_FUNCTIONS"

REAL_SHA256SUM=$(command -v sha256sum)
REAL_SHASUM=$(command -v shasum)

run_installer_case() {
    local case_name=$1
    local checksum_os=${2:-linux}
    local case_dir="$TEST_DIR/$case_name"
    local archive_name="sub2api_1.2.3_${checksum_os}_amd64.tar.gz"
    mkdir -p "$case_dir"

    CHECKSUM_CASE="$case_name" CHECKSUM_OS="$checksum_os" CASE_DIR="$case_dir" ARCHIVE_NAME="$archive_name" \
        REAL_SHA256SUM="$REAL_SHA256SUM" REAL_SHASUM="$REAL_SHASUM" \
        bash -c '
            source "$1"

            msg() { printf "%s" "$1"; }
            print_info() { :; }
            print_error() { :; }
            print_success() { :; }

            LATEST_VERSION=v1.2.3
            OS="$CHECKSUM_OS"
            ARCH=amd64
            INSTALL_DIR="$CASE_DIR/install"
            TAR_CALLED="$CASE_DIR/tar-called"

            curl() {
                local output=""
                local url=""
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -o)
                            output=$2
                            shift 2
                            ;;
                        http://*|https://*)
                            url=$1
                            shift
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done

                case "$url" in
                    */checksums.txt)
                        case "$CHECKSUM_CASE" in
                            download-failure)
                                return 22
                                ;;
                            missing-entry)
                                printf "%064d  other-archive.tar.gz\n" 0 > "$output"
                                ;;
                            checksum-command-failure*)
                                printf "%064d  %s\n" 0 "$ARCHIVE_NAME" > "$output"
                                ;;
                            checksum-mismatch)
                                printf "%064d  %s\n" 0 "$ARCHIVE_NAME" > "$output"
                                ;;
                            success*)
                                local archive_path="${output%/checksums.txt}/$ARCHIVE_NAME"
                                local checksum
                                if [ "$OS" = darwin ]; then
                                    checksum=$("$REAL_SHASUM" -a 256 "$archive_path")
                                else
                                    checksum=$("$REAL_SHA256SUM" "$archive_path")
                                fi
                                checksum=${checksum%%[[:space:]]*}
                                printf "%s  %s\n" "$checksum" "$ARCHIVE_NAME" > "$output"
                                ;;
                        esac
                        ;;
                    *)
                        printf "verified archive payload\n" > "$output"
                        ;;
                esac
            }

            sha256sum() {
                if [[ "$CHECKSUM_CASE" == checksum-command-failure* ]]; then
                    return 1
                fi
                "$REAL_SHA256SUM" "$@"
            }

            shasum() {
                if [[ "$CHECKSUM_CASE" == checksum-command-failure* ]]; then
                    return 1
                fi
                "$REAL_SHASUM" "$@"
            }

            tar() {
                : > "$TAR_CALLED"
                printf "verified binary\n" > "$TEMP_DIR/sub2api"
            }

            download_and_extract
        ' bash "$INSTALL_FUNCTIONS" > "$case_dir/output" 2>&1
}

assert_case_fails_closed() {
    local case_name=$1
    local checksum_os=${2:-linux}
    if run_installer_case "$case_name" "$checksum_os"; then
        echo "checksum case unexpectedly succeeded: $case_name" >&2
        exit 1
    fi
    if [ -e "$TEST_DIR/$case_name/tar-called" ]; then
        echo "checksum failure reached archive extraction: $case_name" >&2
        exit 1
    fi
    if [ -e "$TEST_DIR/$case_name/install/sub2api" ]; then
        echo "checksum failure installed a binary: $case_name" >&2
        exit 1
    fi
}

assert_case_fails_closed download-failure
assert_case_fails_closed missing-entry
assert_case_fails_closed checksum-mismatch
assert_case_fails_closed checksum-command-failure
assert_case_fails_closed checksum-command-failure-darwin darwin

run_installer_case success
test -e "$TEST_DIR/success/tar-called"
test -x "$TEST_DIR/success/install/sub2api"

run_installer_case success-darwin darwin
test -e "$TEST_DIR/success-darwin/tar-called"
test -x "$TEST_DIR/success-darwin/install/sub2api"

echo "install checksum fail-closed checks passed"
