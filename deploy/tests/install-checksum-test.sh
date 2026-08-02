#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_FUNCTIONS="$TEST_DIR/install-functions.sh"
awk '/^download_and_extract\(\) \{/,/^}/' "$ROOT_DIR/deploy/install.sh" > "$INSTALL_FUNCTIONS"

REAL_SHA256SUM=$(command -v sha256sum)
ARCHIVE_NAME=sub2api_1.2.3_linux_amd64.tar.gz

run_installer_case() {
    local case_name=$1
    local case_dir="$TEST_DIR/$case_name"
    mkdir -p "$case_dir"

    CHECKSUM_CASE="$case_name" CASE_DIR="$case_dir" ARCHIVE_NAME="$ARCHIVE_NAME" \
        REAL_SHA256SUM="$REAL_SHA256SUM" \
        bash -c '
            source "$1"

            msg() { printf "%s" "$1"; }
            print_info() { :; }
            print_error() { :; }
            print_success() { :; }

            LATEST_VERSION=v1.2.3
            OS=linux
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
                            checksum-command-failure)
                                printf "%064d  %s\n" 0 "$ARCHIVE_NAME" > "$output"
                                ;;
                            success)
                                local archive_path="${output%/checksums.txt}/$ARCHIVE_NAME"
                                local checksum
                                checksum=$("$REAL_SHA256SUM" "$archive_path")
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
                if [ "$CHECKSUM_CASE" = checksum-command-failure ]; then
                    return 1
                fi
                "$REAL_SHA256SUM" "$@"
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
    if run_installer_case "$case_name"; then
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
assert_case_fails_closed checksum-command-failure

run_installer_case success
test -e "$TEST_DIR/success/tar-called"
test -x "$TEST_DIR/success/install/sub2api"

echo "install checksum fail-closed checks passed"
