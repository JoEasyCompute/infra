#!/usr/bin/env bash

set -euo pipefail

ROOTLESS_ACTION=0
for arg in "$@"; do
    case "${arg}" in
        -h|--help|--list-keys)
            ROOTLESS_ACTION=1
            break
            ;;
    esac
done

if [[ "${EUID}" -ne 0 && "${ROOTLESS_ACTION}" -eq 0 ]]; then
    exec sudo -E "$0" "$@"
fi

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${NC}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_KEY_DIR="${REPO_ROOT}/keys/bootstrap"

ACTION="bootstrap"
TARGET_USER=""
TARGET_SHELL="/bin/bash"
TARGET_COMMENT=""
KEY_NAME=""
KEY_FILE=""
KEY_TEXT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--list-keys] | $(basename "$0") --user <name> [OPTIONS]

Options:
  --list-keys            List repo-managed bootstrap keys and exit
  --user <name>          User to create or update (required unless listing keys)
  --shell <path>         Login shell for new users (default: /bin/bash)
  --comment <text>       GECOS/comment field for new users (default: username)
  --key-name <name>      Repo bootstrap key name under keys/bootstrap/<name>.pub
  --key-file <path>      SSH public key file to install
  --key-text <text>      SSH public key text to install
  --status               Show the current user access state without changing it
  -h, --help             Show this help

Examples:
  sudo $(basename "$0") --list-keys
  sudo $(basename "$0") --user ezc --key-name ezc
  sudo $(basename "$0") --user alice --shell /bin/zsh --key-name alice
  sudo $(basename "$0") --user ezc --key-file /path/to/id_ed25519.pub
  sudo $(basename "$0") --user ezc --key-text "ssh-ed25519 AAAA... comment"
  sudo $(basename "$0") --user ezc --status
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            TARGET_USER="${2:-}"
            [[ -n "${TARGET_USER}" ]] || error "--user requires a value"
            shift 2
            ;;
        --shell)
            TARGET_SHELL="${2:-}"
            [[ -n "${TARGET_SHELL}" ]] || error "--shell requires a value"
            shift 2
            ;;
        --comment)
            TARGET_COMMENT="${2:-}"
            [[ -n "${TARGET_COMMENT}" ]] || error "--comment requires a value"
            shift 2
            ;;
        --key-name)
            KEY_NAME="${2:-}"
            [[ -n "${KEY_NAME}" ]] || error "--key-name requires a value"
            shift 2
            ;;
        --key-file)
            KEY_FILE="${2:-}"
            [[ -n "${KEY_FILE}" ]] || error "--key-file requires a value"
            shift 2
            ;;
        --key-text)
            KEY_TEXT="${2:-}"
            [[ -n "${KEY_TEXT}" ]] || error "--key-text requires a value"
            shift 2
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --list-keys)
            ACTION="list-keys"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

if [[ "${ACTION}" == "list-keys" ]]; then
    if [[ -n "${TARGET_USER}" || -n "${KEY_NAME}" || -n "${KEY_FILE}" || -n "${KEY_TEXT}" || -n "${TARGET_COMMENT}" ]]; then
        error "--list-keys cannot be combined with user or key selection options"
    fi
else
    [[ -n "${TARGET_USER}" ]] || error "--user is required"
    [[ "${TARGET_USER}" != "root" ]] || error "Refusing to manage root via this helper"
    if [[ -n "${KEY_NAME}" && -n "${KEY_FILE}" ]] || [[ -n "${KEY_NAME}" && -n "${KEY_TEXT}" ]] || [[ -n "${KEY_FILE}" && -n "${KEY_TEXT}" ]]; then
        error "--key-name, --key-file, and --key-text are mutually exclusive"
    fi
    if [[ -n "${KEY_NAME}" ]]; then
        case "${KEY_NAME}" in
            (*[!A-Za-z0-9._-]*)
                error "--key-name may only contain letters, numbers, dot, underscore, and hyphen"
                ;;
        esac
    fi
fi

if [[ "${ACTION}" == "bootstrap" && -z "${TARGET_COMMENT}" ]]; then
    TARGET_COMMENT="${TARGET_USER}"
fi

SSH_KEY_SOURCE_TMP=""
SSH_KEY_SOURCE_DESC=""
cleanup() {
    if [[ -n "${SSH_KEY_SOURCE_TMP}" && -f "${SSH_KEY_SOURCE_TMP}" ]]; then
        rm -f "${SSH_KEY_SOURCE_TMP}"
    fi
}
trap cleanup EXIT

list_bootstrap_keys() {
    local key_file key_name key_comment
    local -a key_rows=()

    shopt -s nullglob
    local -a key_files=("${BOOTSTRAP_KEY_DIR}"/*.pub)
    shopt -u nullglob

    section "Bootstrap Keys"
    if [[ "${#key_files[@]}" -eq 0 ]]; then
        warn "No repo-managed bootstrap keys found in ${BOOTSTRAP_KEY_DIR}"
        return
    fi

    for key_file in "${key_files[@]}"; do
        key_name="$(basename "${key_file}" .pub)"
        key_comment="$(awk 'NF { $1=""; $2=""; sub(/^  */, ""); print; exit }' "${key_file}")"
        key_rows+=( "${key_name}"$'\t'"${key_comment}" )
    done

    printf '%-20s %s\n' "Name" "Comment"
    printf '%-20s %s\n' "----" "-------"
    while IFS=$'\t' read -r key_name key_comment; do
        printf '%-20s %s\n' "${key_name}" "${key_comment}"
    done < <(printf '%s\n' "${key_rows[@]}" | sort)

    return 0
}

prepare_ssh_key_source() {
    SSH_KEY_SOURCE_TMP="$(mktemp)"
    if [[ -n "${KEY_NAME}" ]]; then
        local key_path
        key_path="${BOOTSTRAP_KEY_DIR}/${KEY_NAME}.pub"
        [[ -f "${key_path}" ]] || error "Bootstrap key not found: ${key_path}"
        SSH_KEY_SOURCE_DESC="repo key '${KEY_NAME}'"
        grep -vE '^[[:space:]]*#' "${key_path}" | sed '/^[[:space:]]*$/d' > "${SSH_KEY_SOURCE_TMP}"
    elif [[ -n "${KEY_TEXT}" ]]; then
        SSH_KEY_SOURCE_DESC="pasted key text"
        printf '%s\n' "${KEY_TEXT}" | grep -vE '^[[:space:]]*#' | sed '/^[[:space:]]*$/d' > "${SSH_KEY_SOURCE_TMP}"
    elif [[ -n "${KEY_FILE}" ]]; then
        SSH_KEY_SOURCE_DESC="key file '${KEY_FILE}'"
        [[ -f "${KEY_FILE}" ]] || error "SSH key file not found: ${KEY_FILE}"
        grep -vE '^[[:space:]]*#' "${KEY_FILE}" | sed '/^[[:space:]]*$/d' > "${SSH_KEY_SOURCE_TMP}"
    fi
    [[ -s "${SSH_KEY_SOURCE_TMP}" ]] || error "SSH key source is empty"
}

home_dir_for_user() {
    getent passwd "${TARGET_USER}" | awk -F: '{print $6}'
}

group_for_user() {
    id -gn "${TARGET_USER}" 2>/dev/null || echo "${TARGET_USER}"
}

status_report() {
    local home_dir user_group ssh_dir authorized_keys sudoers_file
    home_dir="$(home_dir_for_user 2>/dev/null || true)"
    user_group="$(group_for_user 2>/dev/null || true)"
    ssh_dir="${home_dir}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"
    sudoers_file="/etc/sudoers.d/99-infra-${TARGET_USER}"

    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        success "User exists: ${TARGET_USER}"
    else
        warn "User does not exist: ${TARGET_USER}"
    fi

    if id -nG "${TARGET_USER}" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then
        success "User is in sudo group"
    else
        warn "User is not in sudo group"
    fi

    if [[ -z "${SSH_KEY_SOURCE_TMP}" ]]; then
        warn "No key selector provided; skipping SSH key presence check"
    elif [[ -n "${home_dir}" && -f "${authorized_keys}" ]]; then
        local key_count=0 key_missing=0 key
        while IFS= read -r key; do
            [[ -n "${key}" ]] || continue
            key_count=$((key_count + 1))
            if grep -Fqx "${key}" "${authorized_keys}" 2>/dev/null; then
                continue
            fi
            key_missing=$((key_missing + 1))
        done < "${SSH_KEY_SOURCE_TMP}"

        if [[ "${key_count}" -eq 0 ]]; then
            warn "SSH key source is empty"
        elif [[ "${key_missing}" -eq 0 ]]; then
            success "SSH key source is present in ${authorized_keys}"
        else
            warn "SSH key source is missing ${key_missing}/${key_count} entries in ${authorized_keys}"
        fi
    else
        warn "SSH authorized_keys not present or user home unavailable"
    fi

    if [[ -f "${sudoers_file}" ]]; then
        success "Passwordless sudoers drop-in exists: ${sudoers_file}"
    else
        warn "Passwordless sudoers drop-in is missing: ${sudoers_file}"
    fi
}

ensure_user() {
    if id -u "${TARGET_USER}" >/dev/null 2>&1; then
        info "User already exists: ${TARGET_USER}"
        sudo usermod -aG sudo "${TARGET_USER}" \
            || error "Failed to add ${TARGET_USER} to sudo group"
        success "Ensured ${TARGET_USER} is in sudo group"
        return
    fi

    if ! getent group "${TARGET_USER}" >/dev/null 2>&1; then
        sudo groupadd "${TARGET_USER}" \
            || error "Failed to create primary group ${TARGET_USER}"
    fi

    sudo useradd -m -s "${TARGET_SHELL}" -g "${TARGET_USER}" -G sudo -c "${TARGET_COMMENT}" "${TARGET_USER}" \
        || error "Failed to create user ${TARGET_USER}"
    success "Created user ${TARGET_USER}"
}

install_authorized_keys() {
    local home_dir user_group ssh_dir authorized_keys auth_tmp key
    home_dir="$(home_dir_for_user)"
    user_group="$(group_for_user)"
    ssh_dir="${home_dir}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"

    sudo install -d -m 0700 -o "${TARGET_USER}" -g "${user_group}" "${ssh_dir}"
    auth_tmp="$(mktemp)"
    if [[ -f "${authorized_keys}" ]]; then
        cat "${authorized_keys}" > "${auth_tmp}"
    fi

    while IFS= read -r key; do
        [[ -n "${key}" ]] || continue
        if ! grep -Fxq "${key}" "${auth_tmp}"; then
            printf '%s\n' "${key}" >> "${auth_tmp}"
            success "Added SSH key for ${TARGET_USER}"
        else
            info "SSH key already present for ${TARGET_USER}"
        fi
    done < "${SSH_KEY_SOURCE_TMP}"

    sudo install -m 0600 -o "${TARGET_USER}" -g "${user_group}" "${auth_tmp}" "${authorized_keys}"
    rm -f "${auth_tmp}"
}

install_passwordless_sudo() {
    local sudoers_file sudoers_line
    sudoers_file="/etc/sudoers.d/99-infra-${TARGET_USER}"
    sudoers_line="${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"

    if sudo -l -U "${TARGET_USER}" 2>/dev/null | grep -Eq 'NOPASSWD:[[:space:]]*ALL'; then
        success "${TARGET_USER} already has passwordless sudo"
        return
    fi

    printf '%s\n' "${sudoers_line}" | sudo tee "${sudoers_file}" >/dev/null
    sudo chown root:root "${sudoers_file}"
    sudo chmod 0440 "${sudoers_file}"
    sudo visudo -cf "${sudoers_file}" >/dev/null \
        || error "sudoers validation failed for ${sudoers_file}"
    success "Added passwordless sudoers drop-in for ${TARGET_USER}"
}

case "${ACTION}" in
    list-keys)
        list_bootstrap_keys
        ;;
    status)
        section "User Bootstrap"
        info "Target user: ${TARGET_USER}"
        if [[ -n "${KEY_NAME}" || -n "${KEY_FILE}" || -n "${KEY_TEXT}" ]]; then
            prepare_ssh_key_source
            info "SSH key source: ${SSH_KEY_SOURCE_DESC}"
        fi
        status_report
        ;;
    bootstrap)
        section "User Bootstrap"
        info "Target user: ${TARGET_USER}"
        [[ -n "${KEY_NAME}" || -n "${KEY_FILE}" || -n "${KEY_TEXT}" ]] || error "One of --key-name, --key-file, or --key-text is required"
        prepare_ssh_key_source
        info "SSH key source: ${SSH_KEY_SOURCE_DESC}"
        ensure_user
        install_authorized_keys
        install_passwordless_sudo
        success "User bootstrap complete for ${TARGET_USER}"
        ;;
    *)
        error "Unknown action: ${ACTION}"
        ;;
esac
