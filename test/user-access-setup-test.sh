#!/usr/bin/env bash
# Isolated user-access setup test; no real accounts or sudoers files are changed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/install/user-access-setup.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

TEST_HOME="${TEST_TMP}/home/testuser"
TEST_DOTTED_HOME="${TEST_TMP}/home/jane.doe"
TEST_ROOT="${TEST_TMP}/root"
FAKE_BIN="${TEST_TMP}/bin"
mkdir -p "${TEST_HOME}/.ssh" "${TEST_HOME}/.config/fish" "${TEST_DOTTED_HOME}" \
    "${TEST_ROOT}/etc/sudoers.d" "${FAKE_BIN}"

cat > "${FAKE_BIN}/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == passwd && "$2" == testuser ]]; then
    printf 'testuser:x:1000:1000::%s:/bin/bash\n' "${TEST_HOME}"
    exit 0
fi
if [[ "$1" == passwd && "$2" == jane.doe ]]; then
    printf 'jane.doe:x:1001:1001::%s:/bin/bash\n' "${TEST_DOTTED_HOME}"
    exit 0
fi
exit 2
EOF

cat > "${FAKE_BIN}/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -u)
        case "${2:-}" in
            testuser) printf '1000\n' ;;
            jane.doe) printf '1001\n' ;;
            *) exit 1 ;;
        esac
        ;;
    -gn)
        case "${2:-}" in
            testuser) printf 'staff\n' ;;
            jane.doe) printf 'staff\n' ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "${FAKE_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

map_path() {
    case "$1" in
        /etc/sudoers.d/*)
            printf '%s/etc/sudoers.d/%s\n' "${TEST_ROOT}" "${1##*/}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

case "${1:-}" in
    -u)
        shift 2
        "$@"
        ;;
    -l)
        printf '    (ALL) NOPASSWD: ALL\n'
        ;;
    install)
        shift
        args=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o|-g)
                    shift 2
                    ;;
                *)
                    args+=("$(map_path "$1")")
                    shift
                    ;;
            esac
        done
        command install "${args[@]}"
        ;;
    tee)
        shift
        command tee "$(map_path "$1")"
        ;;
    chown)
        exit 0
        ;;
    chmod)
        shift
        mode="$1"
        shift
        command chmod "${mode}" "$(map_path "$1")"
        ;;
    visudo)
        shift 2
        test -s "$(map_path "$1")"
        ;;
    cat)
        shift
        command cat "$(map_path "$1")"
        ;;
    test)
        shift
        command test "$1" "$(map_path "$2")"
        ;;
    stat)
        shift 3
        mapped_path="$(map_path "$1")"
        stat -c '%a' "${mapped_path}" 2>/dev/null || stat -f '%Lp' "${mapped_path}"
        ;;
    *)
        echo "Unexpected sudo command: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_BIN}/getent" "${FAKE_BIN}/id" "${FAKE_BIN}/sudo"

printf '%s' 'ssh-ed25519 AAAAexisting existing@host' > "${TEST_HOME}/.ssh/authorized_keys"
printf '%s\n' 'alias localonly="printf local"' > "${TEST_HOME}/.aliases"
printf '%s\n' '# custom bash config' > "${TEST_HOME}/.bashrc"
printf '%s\n' '# custom zsh config' > "${TEST_HOME}/.zshrc"
printf '%s\n' '# custom fish config' > "${TEST_HOME}/.config/fish/config.fish"
chmod 0700 "${TEST_HOME}"
chmod 0600 "${TEST_HOME}/.aliases" "${TEST_HOME}/.bashrc" "${TEST_HOME}/.zshrc" \
    "${TEST_HOME}/.config/fish/config.fish"

export TEST_HOME TEST_DOTTED_HOME TEST_ROOT
export PATH="${FAKE_BIN}:${PATH}"
export SUDO_USER=testuser USER=root

"${SCRIPT}"
"${SCRIPT}" --user testuser
"${SCRIPT}" --user jane.doe

ACCESS_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'
AUTHORIZED_KEYS="${TEST_HOME}/.ssh/authorized_keys"
SUDOERS_FILE="${TEST_ROOT}/etc/sudoers.d/99-infra-uid-1000"
DOTTED_SUDOERS_FILE="${TEST_ROOT}/etc/sudoers.d/99-infra-uid-1001"

grep -Fxq 'ssh-ed25519 AAAAexisting existing@host' "${AUTHORIZED_KEYS}"
[[ "$(grep -Fxc "${ACCESS_KEY}" "${AUTHORIZED_KEYS}")" -eq 1 ]]
[[ "$(grep -Fxc '# >>> infra aliases from repo >>>' "${TEST_HOME}/.aliases")" -eq 1 ]]
grep -Fxq 'alias localonly="printf local"' "${TEST_HOME}/.aliases"
grep -Fxq '# custom bash config' "${TEST_HOME}/.bashrc"
grep -Fxq '# custom zsh config' "${TEST_HOME}/.zshrc"
grep -Fxq '# custom fish config' "${TEST_HOME}/.config/fish/config.fish"
[[ "$(grep -Fxc '# >>> infra aliases from repo >>>' "${TEST_HOME}/.bashrc")" -eq 1 ]]
[[ "$(grep -Fxc '# >>> infra aliases from repo >>>' "${TEST_HOME}/.zshrc")" -eq 1 ]]
[[ "$(grep -Fxc '# >>> infra aliases from repo >>>' "${TEST_HOME}/.config/fish/config.fish")" -eq 1 ]]
test -s "${TEST_HOME}/.aliases.fish"
grep -Fxq 'testuser ALL=(ALL) NOPASSWD:ALL' "${SUDOERS_FILE}"
grep -Fxq 'jane.doe ALL=(ALL) NOPASSWD:ALL' "${DOTTED_SUDOERS_FILE}"

mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

[[ "$(mode_of "${TEST_HOME}/.ssh")" == 700 ]]
[[ "$(mode_of "${TEST_HOME}")" == 700 ]]
[[ "$(mode_of "${AUTHORIZED_KEYS}")" == 600 ]]
[[ "$(mode_of "${TEST_HOME}/.aliases")" == 600 ]]
[[ "$(mode_of "${TEST_HOME}/.bashrc")" == 600 ]]
[[ "$(mode_of "${TEST_HOME}/.zshrc")" == 600 ]]
[[ "$(mode_of "${TEST_HOME}/.config/fish/config.fish")" == 600 ]]
[[ "$(mode_of "${SUDOERS_FILE}")" == 440 ]]

if "${SCRIPT}" --user missing >/dev/null 2>&1; then
    echo 'FAIL: missing user was accepted' >&2
    exit 1
fi

echo 'Standalone user access setup checks passed'
