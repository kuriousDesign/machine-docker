#!/usr/bin/env bash

set -euo pipefail

NIC_NAME="${NIC_NAME:-enp3s0}"
CPU_CORE="${CPU_CORE:-3}"
INSTALL_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"

usage() {
    cat <<EOF
Usage: sudo ./setup/ethercat-network-tuning.sh [--nic <name>] [--cpu <core>]

Installs a persistent systemd oneshot service that tunes an EtherCAT NIC for
lower latency and pins its IRQs to a dedicated CPU core.

Options:
  --nic <name>   Network interface to tune (default: ${NIC_NAME})
  --cpu <core>   Zero-based Linux CPU index for IRQ affinity (default: ${CPU_CORE})
  --help         Show this message

Environment overrides:
  NIC_NAME=<name>
  CPU_CORE=<core>
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
                NIC_NAME="$2"
                shift 2
                ;;
            --cpu)
                CPU_CORE="$2"
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
    if [[ ! "$CPU_CORE" =~ ^[0-9]+$ ]]; then
        echo "CPU core must be a zero-based integer. Got: $CPU_CORE" >&2
        exit 1
    fi

    if [[ ! -d "/sys/class/net/${NIC_NAME}" ]]; then
        echo "Network interface not found: $NIC_NAME" >&2
        exit 1
    fi
}

install_helper_script() {
    local helper_script_path="${INSTALL_DIR}/set-${NIC_NAME}-rt-affinity.sh"

    install -d "$INSTALL_DIR"
    cat >"$helper_script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

NIC_NAME="${NIC_NAME}"
CPU_CORE="${CPU_CORE}"

if [[ ! -d "/sys/class/net/\${NIC_NAME}" ]]; then
    echo "NIC \${NIC_NAME} not found" >&2
    exit 1
fi

# EtherCAT-friendly NIC tuning: single queue, no interrupt coalescing,
# no latency-adding offloads, and a simple FIFO qdisc.
ethtool -L "\${NIC_NAME}" combined 1
ethtool -C "\${NIC_NAME}" rx-usecs 0 tx-usecs 0
ethtool -K "\${NIC_NAME}" gro off gso off tso off sg off rx off tx off rxhash off

if command -v tc >/dev/null 2>&1; then
    tc qdisc replace dev "\${NIC_NAME}" root pfifo_fast || true
fi

mapfile -t irqs < <(grep -iE "[[:space:]]\${NIC_NAME}([:-]|$)" /proc/interrupts | cut -d: -f1 | tr -d " ")

if [[ \${#irqs[@]} -eq 0 ]]; then
    echo "No IRQs found for \${NIC_NAME}" >&2
    exit 1
fi

for irq in "\${irqs[@]}"; do
    echo "\${CPU_CORE}" > "/proc/irq/\${irq}/smp_affinity_list"
done

echo "Applied EtherCAT NIC tuning for \${NIC_NAME} on CPU \${CPU_CORE}."
EOF
    chmod 755 "$helper_script_path"
    echo "Installed helper script at $helper_script_path"
}

install_service() {
    local service_name="${NIC_NAME}-rt-network-tuning.service"
    local service_path="${SYSTEMD_DIR}/${service_name}"
    local helper_script_path="${INSTALL_DIR}/set-${NIC_NAME}-rt-affinity.sh"

    cat >"$service_path" <<EOF
[Unit]
Description=Tune ${NIC_NAME} for EtherCAT and pin IRQs to CPU ${CPU_CORE}
After=network-online.target sys-subsystem-net-devices-${NIC_NAME}.device
Wants=network-online.target
BindsTo=sys-subsystem-net-devices-${NIC_NAME}.device
ConditionPathExists=/sys/class/net/${NIC_NAME}

[Service]
Type=oneshot
ExecStart=${helper_script_path}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$service_name"
    echo "Installed and enabled $service_name"
}

verify_runtime_state() {
    local service_name="${NIC_NAME}-rt-network-tuning.service"

    echo
    systemctl status "$service_name" --no-pager -l
    echo
    ethtool -l "$NIC_NAME"
    echo
    ethtool -c "$NIC_NAME"
    echo
    ethtool -k "$NIC_NAME" | grep -E 'rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|receive-hashing'
    echo
    if command -v tc >/dev/null 2>&1; then
        tc qdisc show dev "$NIC_NAME"
        echo
    fi
    grep -i "$NIC_NAME" /proc/interrupts || true
}

main() {
    parse_args "$@"
    require_root
    require_command ethtool
    require_command systemctl
    require_command grep
    require_command cut
    require_command tr
    validate_inputs
    install_helper_script
    install_service
    verify_runtime_state
}

main "$@"