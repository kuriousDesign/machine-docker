#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-}"
INSTALL_DOCKER_DESKTOP_COMPAT="${INSTALL_DOCKER_DESKTOP_COMPAT:-0}"
APT_KEYRING_DIR="/etc/apt/keyrings"
DOCKER_KEYRING_PATH="${APT_KEYRING_DIR}/docker.asc"
DOCKER_SOURCES_FILE="/etc/apt/sources.list.d/docker.list"
DOCKER_PACKAGES=(
    ca-certificates
    curl
    gnupg
    lsb-release
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

usage() {
    cat <<EOF
Usage: sudo ./setup/docker-install.sh [--user <linux-user>] [--with-docker-desktop-compat]

Installs Docker Engine and the Docker Compose plugin from Docker's official apt
repository on Ubuntu, then optionally adds a Linux user to the docker group.

Options:
  --user <linux-user>             User to add to the docker group after install
  --with-docker-desktop-compat    Install docker-compose-v2 for older Docker Desktop integrations
  --help                          Show this message

Environment overrides:
  TARGET_USER=<linux-user>
  INSTALL_DOCKER_DESKTOP_COMPAT=1

Notes:
- intended for Ubuntu-based systems
- on WSL, this installs Docker inside the distro rather than relying on Docker Desktop integration
- group membership changes apply to new login shells only
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
            --with-docker-desktop-compat)
                INSTALL_DOCKER_DESKTOP_COMPAT="1"
                shift
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

validate_os() {
    local os_id
    local os_like

    if [[ ! -r /etc/os-release ]]; then
        echo "Unable to determine OS details from /etc/os-release" >&2
        exit 1
    fi

    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    os_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"

    if [[ "$os_id" != "ubuntu" && "$os_like" != *ubuntu* && "$os_like" != *debian* ]]; then
        echo "This installer currently supports Ubuntu or Debian-like systems only. Detected: ${os_id:-unknown}" >&2
        exit 1
    fi
}

validate_inputs() {
    if [[ -n "$TARGET_USER" ]] && ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "User not found: $TARGET_USER" >&2
        exit 1
    fi
}

install_apt_prerequisites() {
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
}

configure_docker_apt_repo() {
    local arch
    local codename

    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"

    install -d -m 0755 "$APT_KEYRING_DIR"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEYRING_PATH"
    chmod a+r "$DOCKER_KEYRING_PATH"

    cat >"$DOCKER_SOURCES_FILE" <<EOF
deb [arch=${arch} signed-by=${DOCKER_KEYRING_PATH}] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

    apt-get update
}

install_docker_packages() {
    local packages=("${DOCKER_PACKAGES[@]}")

    if [[ "$INSTALL_DOCKER_DESKTOP_COMPAT" == "1" ]]; then
        packages+=(docker-compose-v2)
    fi

    apt-get install -y "${packages[@]}"
}

enable_and_start_docker() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl enable --now docker
        systemctl enable --now containerd
        echo "Enabled and started docker and containerd services"
        return
    fi

    echo "systemd is not active in this environment; Docker was installed but not started automatically"
    echo "If this is WSL, install systemd support or start dockerd manually"
}

configure_user_group() {
    if [[ -z "$TARGET_USER" ]]; then
        return
    fi

    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -Fxq docker; then
        echo "User ${TARGET_USER} is already in the docker group"
        return
    fi

    usermod -aG docker "$TARGET_USER"
    echo "Added ${TARGET_USER} to the docker group"
    echo "Open a new login shell or sign out and back in before using docker without sudo"
}

print_summary() {
    echo
    docker --version
    docker compose version
    echo
    echo "Docker installation complete."
    if [[ -n "$TARGET_USER" ]]; then
        echo "User configured for docker group access: ${TARGET_USER}"
    fi
}

main() {
    parse_args "$@"
    require_root
    require_command apt-get
    require_command curl
    require_command dpkg
    require_command gpg
    require_command grep
    require_command id
    require_command install
    require_command tr
    require_command usermod
    validate_os
    validate_inputs
    install_apt_prerequisites
    configure_docker_apt_repo
    install_docker_packages
    enable_and_start_docker
    configure_user_group
    print_summary
}

main "$@"