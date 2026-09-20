#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${NC}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALIAS_SOURCE="${REPO_ROOT}/.aliases"
ACCESS_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'
TARGET_USER="${SUDO_USER:-${USER:-}}"
MANAGED_START='# >>> infra aliases from repo >>>'
MANAGED_END='# <<< infra aliases from repo <<<'

usage() {
    cat <<EOF
Usage: $(basename "$0") [--user <name>]

Install the repo-managed SSH key, passwordless sudo, and shell aliases for an
existing local user. The invoking sudo user is used by default.

Options:
  --user <name>  Existing user to configure (default: invoking sudo user)
  -h, --help     Show this help

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --user ezc
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            TARGET_USER="${2:-}"
            [[ -n "${TARGET_USER}" ]] || error "--user requires a value"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

[[ -n "${TARGET_USER}" ]] || error "Cannot determine the target user; pass --user <name>"
case "${TARGET_USER}" in
    root)
        error "Refusing to configure root"
        ;;
    *[!A-Za-z0-9._-]*)
        error "Invalid user name: ${TARGET_USER}"
        ;;
esac
id -u "${TARGET_USER}" >/dev/null 2>&1 || error "User does not exist: ${TARGET_USER}"
[[ -f "${ALIAS_SOURCE}" ]] || error "Repo alias file not found: ${ALIAS_SOURCE}"

TARGET_HOME="$(getent passwd "${TARGET_USER}" | awk -F: 'NR == 1 { print $6 }')"
[[ "${TARGET_HOME}" == /* && -d "${TARGET_HOME}" ]] \
    || error "Cannot resolve the home directory for ${TARGET_USER}"
TARGET_UID="$(id -u "${TARGET_USER}")"
TARGET_GROUP="$(id -gn "${TARGET_USER}")" \
    || error "Cannot resolve the primary group for ${TARGET_USER}"

install_user_access() {
    section "User Access"

    local ssh_dir authorized_keys auth_tmp
    ssh_dir="${TARGET_HOME}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"
    auth_tmp="$(mktemp)"

    sudo install -d -m 0700 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${ssh_dir}"
    if [[ -f "${authorized_keys}" ]]; then
        sudo cat "${authorized_keys}" > "${auth_tmp}"
    fi
    if grep -Fxq "${ACCESS_KEY}" "${auth_tmp}"; then
        info "SSH authorized key already present in ${authorized_keys}"
    else
        if [[ -s "${auth_tmp}" ]] && ! tail -c 1 "${auth_tmp}" | grep -q '^$'; then
            printf '\n' >> "${auth_tmp}"
        fi
        printf '%s\n' "${ACCESS_KEY}" >> "${auth_tmp}"
        success "Added SSH authorized key for ${TARGET_USER}"
    fi
    sudo install -m 0600 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${auth_tmp}" "${authorized_keys}"
    rm -f "${auth_tmp}"

    local sudoers_file sudoers_line sudoers_tmp
    sudoers_file="/etc/sudoers.d/99-infra-uid-${TARGET_UID}"
    sudoers_line="${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"

    sudoers_tmp="$(mktemp)"
    printf '%s\n' "${sudoers_line}" > "${sudoers_tmp}"
    sudo visudo -cf "${sudoers_tmp}" >/dev/null \
        || { rm -f "${sudoers_tmp}"; error "sudoers validation failed for ${TARGET_USER}"; }
    sudo install -m 0440 -o root -g root "${sudoers_tmp}" "${sudoers_file}"
    rm -f "${sudoers_tmp}"
    success "Installed passwordless sudoers drop-in for ${TARGET_USER}"
}

ensure_target_dir() {
    local target_dir="$1" mode="$2"
    if sudo test -d "${target_dir}"; then
        return
    fi
    sudo install -d -m "${mode}" -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${target_dir}"
}

file_mode_or_default() {
    local target_file="$1" default_mode="$2"
    if sudo test -f "${target_file}"; then
        sudo stat -c '%a' "${target_file}"
    else
        printf '%s\n' "${default_mode}"
    fi
}

without_managed_block() {
    local source_file="$1" output_file="$2" source_tmp
    if ! sudo test -f "${source_file}"; then
        : > "${output_file}"
        return
    fi
    source_tmp="$(mktemp)"
    sudo cat "${source_file}" > "${source_tmp}"
    awk -v start="${MANAGED_START}" -v end="${MANAGED_END}" '
        BEGIN { skip = 0 }
        $0 == start { skip = 1; next }
        $0 == end { skip = 0; next }
        skip == 0 { print }
    ' "${source_tmp}" > "${output_file}"
    rm -f "${source_tmp}"
}

install_rc_block() {
    local rc_file="$1" rc_body="$2" rc_tmp rc_mode
    rc_tmp="$(mktemp)"
    rc_mode="$(file_mode_or_default "${rc_file}" 0644)"
    ensure_target_dir "$(dirname "${rc_file}")" 0755
    without_managed_block "${rc_file}" "${rc_tmp}"
    {
        printf '\n%s\n' "${MANAGED_START}"
        printf '%s\n' "${rc_body}"
        printf '%s\n' "${MANAGED_END}"
    } >> "${rc_tmp}"
    sudo install -m "${rc_mode}" -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${rc_tmp}" "${rc_file}"
    rm -f "${rc_tmp}"
}

install_shell_aliases() {
    section "Shell Aliases"

    local aliases_file bashrc zshrc fish_config fish_aliases aliases_tmp fish_tmp aliases_mode fish_mode
    aliases_file="${TARGET_HOME}/.aliases"
    bashrc="${TARGET_HOME}/.bashrc"
    zshrc="${TARGET_HOME}/.zshrc"
    fish_config="${TARGET_HOME}/.config/fish/config.fish"
    fish_aliases="${TARGET_HOME}/.aliases.fish"
    aliases_tmp="$(mktemp)"
    fish_tmp="$(mktemp)"
    aliases_mode="$(file_mode_or_default "${aliases_file}" 0644)"
    fish_mode="$(file_mode_or_default "${fish_aliases}" 0644)"

    without_managed_block "${aliases_file}" "${aliases_tmp}"
    {
        printf '\n%s\n' "${MANAGED_START}"
        cat "${ALIAS_SOURCE}"
        printf '%s\n' "${MANAGED_END}"
    } >> "${aliases_tmp}"
    sudo install -m "${aliases_mode}" -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${aliases_tmp}" "${aliases_file}"
    rm -f "${aliases_tmp}"
    success "Installed ${aliases_file}"

    install_rc_block "${bashrc}" '[ -f "$HOME/.aliases" ] && . "$HOME/.aliases"'
    install_rc_block "${zshrc}" '[ -f "$HOME/.aliases" ] && . "$HOME/.aliases"'

    {
        printf '# Autogenerated by user-access-setup.sh from repo .aliases\n'
        printf '# Fish wrappers call bash so the repo bash aliases stay the single source of truth.\n\n'
        while IFS= read -r alias_line; do
            [[ "${alias_line}" =~ ^alias[[:space:]]+\'([^\']+)\'= ]] || continue
            local alias_name="${BASH_REMATCH[1]}"
            printf "function %s --description 'Repo alias from ~/.aliases'\n" "${alias_name}"
            printf '    bash -lc '\''source "$HOME/.aliases"; %s'\''\n' "${alias_name}"
            printf 'end\n\n'
        done < "${ALIAS_SOURCE}"
    } > "${fish_tmp}"
    sudo install -m "${fish_mode}" -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${fish_tmp}" "${fish_aliases}"
    rm -f "${fish_tmp}"

    install_rc_block "${fish_config}" 'if test -f "$HOME/.aliases.fish"
    source "$HOME/.aliases.fish"
end'
    success "Updated Bash, Zsh, and Fish alias configuration"

    sudo -u "${TARGET_USER}" bash -n "${aliases_file}" \
        || error "Failed to validate ${aliases_file}"
    success "Validated ${aliases_file}"
}

install_user_access
install_shell_aliases
success "User access setup complete for ${TARGET_USER}"
