#!/usr/bin/env bash
# Isolated SSH configuration tests; no real SSH daemon or sudo is used.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
for installer in base-install.sh amd-base-install.sh; do
    for scenario in success invalid match reload; do
        (
            case_dir="$TEST_TMP/$installer-$scenario"
            mkdir -p "$case_dir/home" "$case_dir/etc"
            printf '# existing config\nPasswordAuthentication yes\n' > "$case_dir/etc/sshd_config"
            cp "$case_dir/etc/sshd_config" "$case_dir/original"
            printf '#!/bin/sh\nexit 0\n' > "$case_dir/sshd"
            chmod +x "$case_dir/sshd"
            function_text=$(awk '/^finalize_ssh_access\(\) \{/ {copy=1} copy {print} copy && /^}$/ {exit}' "$ROOT_DIR/install/$installer")
            function_text=${function_text//\/etc\/ssh\/sshd_config/$case_dir/etc/sshd_config}
            function_text=${function_text//\/usr\/sbin\/sshd/$case_dir/sshd}
            eval "$function_text"
            info() { :; }; section() { :; }; success() { :; }; warn() { :; }
            error() { echo "$*" >&2; exit 1; }
            getent() { printf 'ezc:x:1000:1000::%s:/bin/bash\n' "$case_dir/home"; }
            id() { echo staff; }
            SUDO_USER=ezc SSH_CONNECTION='192.0.2.10 1234 192.0.2.20 22'
            sudo() {
                if [[ "$1" == "$case_dir/sshd" ]]; then
                    shift
                    if [[ "$1" == -t ]]; then
                        [[ "$scenario" != invalid || $# == 1 ]]
                    else
                        printf 'pubkeyauthentication yes\nkbdinteractiveauthentication no\nauthenticationmethods any\nauthorizedkeysfile .ssh/authorized_keys\n'
                        if [[ "$scenario" == match ]]; then echo 'passwordauthentication yes'; else echo 'passwordauthentication no'; fi
                    fi
                elif [[ "$1" == systemctl ]]; then
                    echo reload >> "$case_dir/reloads"
                    [[ "$scenario" != reload ]]
                elif [[ "$1" == -u ]]; then
                    shift 2
                    "$@"
                elif [[ "$1" == install ]]; then
                    shift
                    local args=()
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            -o|-g) shift 2 ;;
                            *) args+=("$1"); shift ;;
                        esac
                    done
                    command install "${args[@]}"
                else
                    "$@"
                fi
            }
            if [[ "$scenario" == success ]]; then
                finalize_ssh_access
                finalize_ssh_access
                [[ $(grep -c '^# BEGIN infra SSH key-only login$' "$case_dir/etc/sshd_config") == 1 ]]
                [[ $(grep -c '^ssh-ed25519 ' "$case_dir/home/.ssh/authorized_keys") == 1 ]]
                [[ $(head -2 "$case_dir/etc/sshd_config" | tail -1) == 'PubkeyAuthentication yes' ]]
                grep -Fxq 'PasswordAuthentication no' "$case_dir/etc/sshd_config"
                [[ -f "$case_dir/reloads" ]]
            else
                if (finalize_ssh_access) > /dev/null 2>&1; then
                    echo "FAIL: $installer accepted $scenario" >&2; exit 1
                fi
                cmp "$case_dir/original" "$case_dir/etc/sshd_config"
                if [[ "$scenario" != reload ]]; then [[ ! -f "$case_dir/reloads" ]]; fi
            fi
        )
    done
done
echo 'Both installers: SSH validation, idempotence and rollback checks passed'
