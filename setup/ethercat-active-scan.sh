#!/usr/bin/env bash

set -euo pipefail

NIC_NAME="${NIC_NAME:-enp3s0}"
WORK_DIR="${WORK_DIR:-/var/tmp/machine-docker-soem}"
SOEM_REPO_URL="${SOEM_REPO_URL:-https://github.com/OpenEtherCATsociety/SOEM.git}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:24.04}"
BUILD_ONLY="false"
LEAVE_RUNTIME_STOPPED="false"

SOEM_SRC_DIR=""
SOEM_BUILD_DIR=""
RUNTIME_WAS_ACTIVE="false"
RUNTIME_STOPPED_BY_SCRIPT="false"

usage() {
    cat <<EOF
Usage: sudo ./setup/ethercat-active-scan.sh [--nic <name>] [--build-only] [--leave-runtime-stopped]

Builds SOEM slaveinfo in a temporary Dockerized build environment, optionally
stops CODESYS runtime, runs an EtherCAT slave scan on one NIC, and restores the
runtime afterwards.

Options:
  --nic <name>              Network interface to scan (default: ${NIC_NAME})
  --build-only              Only fetch and build the SOEM scanner; do not stop runtime or scan
  --leave-runtime-stopped   Do not restart CODESYS runtime after the scan
  --work-dir <path>         Cache directory for the SOEM source and build output
                            (default: ${WORK_DIR})
  --image <name>            Docker image used for the build and scan runtime
                            (default: ${DOCKER_IMAGE})
  --help                    Show this message

Environment overrides:
  NIC_NAME=<name>
  WORK_DIR=<path>
  SOEM_REPO_URL=<url>
  DOCKER_IMAGE=<name>

Notes:
- This script requires Docker, git, and root privileges.
- The scan is active: it temporarily takes over the NIC as an EtherCAT master.
- If CODESYS runtime is active, the script stops it before scanning unless
  --build-only is used.
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
            --nic)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --nic" >&2
                    usage >&2
                    exit 1
                fi
                NIC_NAME="$2"
                shift 2
                ;;
            --build-only)
                BUILD_ONLY="true"
                shift
                ;;
            --leave-runtime-stopped)
                LEAVE_RUNTIME_STOPPED="true"
                shift
                ;;
            --work-dir)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --work-dir" >&2
                    usage >&2
                    exit 1
                fi
                WORK_DIR="$2"
                shift 2
                ;;
            --image)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --image" >&2
                    usage >&2
                    exit 1
                fi
                DOCKER_IMAGE="$2"
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
    if ! ip link show "$NIC_NAME" >/dev/null 2>&1; then
        echo "Network interface not found: $NIC_NAME" >&2
        exit 1
    fi
}

codesys_is_active() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet codesyscontrol; then
            return 0
        fi
    fi

    if [[ -x /etc/init.d/codesyscontrol ]] && /etc/init.d/codesyscontrol status >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

codesys_action() {
    local action="$1"

    if [[ -x /usr/local/sbin/codesys-control-action ]]; then
        /usr/local/sbin/codesys-control-action "$action"
        return
    fi

    if [[ -x /etc/init.d/codesyscontrol ]]; then
        /etc/init.d/codesyscontrol "$action"
        return
    fi

    echo "No CODESYS runtime control command found." >&2
    exit 1
}

prepare_workdir() {
    SOEM_SRC_DIR="${WORK_DIR}/source"
    SOEM_BUILD_DIR="${WORK_DIR}/build"

    install -d "$WORK_DIR"

    if [[ ! -d "${SOEM_SRC_DIR}/.git" ]]; then
        git clone --depth 1 "$SOEM_REPO_URL" "$SOEM_SRC_DIR"
    else
        git -C "$SOEM_SRC_DIR" fetch --depth 1 origin
        git -C "$SOEM_SRC_DIR" reset --hard FETCH_HEAD
    fi

    install -d "$SOEM_BUILD_DIR"
}

build_slaveinfo() {
    docker pull "$DOCKER_IMAGE" >/dev/null

    docker run --rm \
        -v "$SOEM_SRC_DIR":/work/source \
        -v "$SOEM_BUILD_DIR":/work/build \
        -w /work/source \
        "$DOCKER_IMAGE" \
        bash -lc '
            export DEBIAN_FRONTEND=noninteractive
            apt-get update >/dev/null
            apt-get install -y --no-install-recommends build-essential cmake ca-certificates >/dev/null
            cmake -S /work/source -B /work/build -DCMAKE_BUILD_TYPE=Release >/dev/null
            cmake --build /work/build --target slaveinfo >/dev/null
        '
}

restart_runtime_if_needed() {
    if [[ "$RUNTIME_STOPPED_BY_SCRIPT" != "true" ]]; then
        return
    fi

    if [[ "$LEAVE_RUNTIME_STOPPED" == "true" ]]; then
        echo "Leaving CODESYS runtime stopped because --leave-runtime-stopped was requested."
        return
    fi

    echo "Restarting CODESYS runtime..."
    codesys_action start
}

run_scan() {
    local binary_path="${SOEM_BUILD_DIR}/samples/slaveinfo/slaveinfo"

    if [[ ! -x "$binary_path" ]]; then
        echo "SOEM slaveinfo binary not found after build: $binary_path" >&2
        exit 1
    fi

    docker run --rm \
        --network host \
        --privileged \
        -v "$SOEM_BUILD_DIR":/work/build \
        "$DOCKER_IMAGE" \
        bash -lc "/work/build/samples/slaveinfo/slaveinfo '$NIC_NAME'"
}

main() {
    parse_args "$@"
    require_root
    require_command docker
    require_command git
    require_command ip
    validate_inputs
    prepare_workdir
    build_slaveinfo

    if [[ "$BUILD_ONLY" == "true" ]]; then
        echo "SOEM slaveinfo built successfully under ${SOEM_BUILD_DIR}."
        exit 0
    fi

    trap restart_runtime_if_needed EXIT

    if codesys_is_active; then
        RUNTIME_WAS_ACTIVE="true"
        echo "Stopping CODESYS runtime before active EtherCAT scan..."
        codesys_action stop
        RUNTIME_STOPPED_BY_SCRIPT="true"
    else
        echo "CODESYS runtime is already stopped."
    fi

    run_scan
}

main "$@"