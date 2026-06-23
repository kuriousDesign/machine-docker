#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-}"
NODE_VERSION="${NODE_VERSION:-v22.21.1}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"

usage() {
    cat <<EOF
Usage: sudo ./setup/node-install.sh [--user <linux-user>] [--node-version <version>] [--nvm-version <version>]

Installs nvm for a Linux user, installs the requested Node.js version, and
sets that version as the default for future shells.

Options:
  --user <linux-user>       Linux account that should own the nvm installation
  --node-version <version>  Node.js version to install (default: ${NODE_VERSION})
  --nvm-version <version>   nvm git tag to install (default: ${NVM_VERSION})
  --help                    Show this message

Environment overrides:
  TARGET_USER=<linux-user>
  NODE_VERSION=<version>
  NVM_VERSION=<version>

If --user and TARGET_USER are omitted, the script uses the invoking sudo user.
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Run this script with sudo or as root." >&2
        exit 1
    fi
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 1
    fi
}

resolve_target_user() {
    if [[ -n "$TARGET_USER" ]]; then
        return
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
        return
    fi

    echo "Unable to determine the target user automatically. Re-run with --user <name> or TARGET_USER=<name>." >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --user" >&2
                    usage >&2
                    exit 1
                fi
                TARGET_USER="$2"
                shift 2
                ;;
            --node-version)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --node-version" >&2
                    usage >&2
                    exit 1
                fi
                NODE_VERSION="$2"
                shift 2
                ;;
            --nvm-version)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --nvm-version" >&2
                    usage >&2
                    exit 1
                fi
                NVM_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

validate_inputs() {
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "User not found: $TARGET_USER" >&2
        exit 1
    fi

    if [[ ! "$NODE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Node version must look like v22.21.1 or 22.21.1. Got: $NODE_VERSION" >&2
        exit 1
    fi

    if [[ ! "$NVM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "nvm version must look like v0.40.3. Got: $NVM_VERSION" >&2
        exit 1
    fi
}

resolve_user_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

install_system_prerequisites() {
    apt-get update
    apt-get install -y ca-certificates curl git
}

install_nvm() {
    local user_home="$1"
    local nvm_dir="${user_home}/.nvm"

    if [[ -e "$nvm_dir" && ! -d "$nvm_dir/.git" ]]; then
        echo "Existing path is not an nvm git checkout: $nvm_dir" >&2
        exit 1
    fi

    if [[ ! -d "$nvm_dir/.git" ]]; then
        runuser -u "$TARGET_USER" -- env HOME="$user_home" git clone https://github.com/nvm-sh/nvm.git "$nvm_dir"
    fi

    runuser -u "$TARGET_USER" -- env HOME="$user_home" git -C "$nvm_dir" fetch --tags origin
    runuser -u "$TARGET_USER" -- env HOME="$user_home" git -C "$nvm_dir" checkout "$NVM_VERSION"

    echo "Installed nvm ${NVM_VERSION} in ${nvm_dir}"
}

ensure_profile_init() {
    local user_home="$1"
    local profile_path="$2"

    runuser -u "$TARGET_USER" -- env HOME="$user_home" bash -c '
profile_path="$1"
marker="# >>> nvm setup >>>"

touch "$profile_path"

if grep -Fq "$marker" "$profile_path"; then
    exit 0
fi

cat >> "$profile_path" <<"EOF"

# >>> nvm setup >>>
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    . "$NVM_DIR/nvm.sh"
fi
# <<< nvm setup <<<
EOF
' bash "$profile_path"
}

install_node_version() {
    local user_home="$1"
    local nvm_dir="${user_home}/.nvm"

    runuser -u "$TARGET_USER" -- env HOME="$user_home" bash -c '
export NVM_DIR="$1"
export NODE_VERSION="$2"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    echo "nvm.sh not found in $NVM_DIR" >&2
    exit 1
fi

. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use default >/dev/null

printf "Installed Node.js: "
node -v
printf "npm version: "
npm -v
' bash "$nvm_dir" "$NODE_VERSION"
}

main() {
    local user_home

    parse_args "$@"
    require_root
    resolve_target_user
    require_command apt-get
    require_command bash
    require_command curl
    require_command getent
    require_command git
    require_command grep
    require_command id
    require_command runuser
    validate_inputs

    user_home="$(resolve_user_home)"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "Unable to determine home directory for $TARGET_USER" >&2
        exit 1
    fi

    install_system_prerequisites
    install_nvm "$user_home"
    ensure_profile_init "$user_home" "${user_home}/.bashrc"
    ensure_profile_init "$user_home" "${user_home}/.profile"
    install_node_version "$user_home"

    echo
    echo "Configured nvm for $TARGET_USER with default Node.js ${NODE_VERSION}"
    echo "Open a new shell or run: source ~/.bashrc"
}

main "$@"