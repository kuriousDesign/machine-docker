#!/usr/bin/env bash

set -euo pipefail

NIC="${NIC:-enp2s0}"
ADDRESS_CIDR="${ADDRESS_CIDR:-192.168.102.1/24}"
NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/99-${NIC}-static-ip.yaml"

usage() {
    cat <<EOF
Usage: sudo ./setup/network-static-ip.sh [--nic <name>] [--address <ipv4/cidr>]

Configures a persistent static IPv4 address on a host network interface.

Options:
    --nic <name>         Interface name to configure (default: ${NIC})
    --address <ipv4/cidr> Static IPv4 address in CIDR form (default: ${ADDRESS_CIDR})
  --help               Show this message

Environment overrides:
  NIC=<name>
  ADDRESS_CIDR=<ipv4/cidr>

Behavior:
- prefers NetworkManager when nmcli is available
- otherwise writes a dedicated netplan file and applies it
- disables DHCP on the target interface
- avoids installing a default route for the interface
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
                NIC="$2"
                shift 2
                ;;
            --address)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --address" >&2
                    usage >&2
                    exit 1
                fi
                ADDRESS_CIDR="$2"
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
    if [[ ! "$NIC" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
        echo "Invalid interface name: $NIC" >&2
        exit 1
    fi

    if [[ ! "$ADDRESS_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        echo "Address must be in IPv4 CIDR format, for example 192.168.102.1/24. Got: $ADDRESS_CIDR" >&2
        exit 1
    fi

    if ! ip link show "$NIC" >/dev/null 2>&1; then
        echo "Network interface not found: $NIC" >&2
        exit 1
    fi
}

find_connection_name() {
    local connection_name=""

    connection_name="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v nic="$NIC" '$2 == nic { print $1; exit }')"

    if [[ -z "$connection_name" ]]; then
        connection_name="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v nic="$NIC" '$2 == nic { print $1; exit }')"
    fi

    if [[ -z "$connection_name" ]]; then
        connection_name="machine-docker-${NIC}-static"
        nmcli connection add type ethernet ifname "$NIC" con-name "$connection_name"
    fi

    printf '%s\n' "$connection_name"
}

configure_with_nmcli() {
    local connection_name

    require_command nmcli
    connection_name="$(find_connection_name)"

    nmcli connection modify "$connection_name" \
        connection.interface-name "$NIC" \
        connection.autoconnect yes \
        ipv4.method manual \
        ipv4.addresses "$ADDRESS_CIDR" \
        ipv4.gateway "" \
        ipv4.never-default yes \
        ipv6.method ignore

    nmcli connection up "$connection_name"

    echo "Configured ${NIC} with ${ADDRESS_CIDR} via NetworkManager connection ${connection_name}."
}

configure_with_netplan() {
    require_command install

    install -d "$NETPLAN_DIR"

    cat >"$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${NIC}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${ADDRESS_CIDR}
      optional: true
      link-local: []
EOF

    require_command netplan
    netplan generate
    netplan apply

    echo "Configured ${NIC} with ${ADDRESS_CIDR} via netplan file ${NETPLAN_FILE}."
}

print_live_state() {
    echo
    echo "Live interface state for ${NIC}:"
    ip -4 addr show dev "$NIC"
}

main() {
    parse_args "$@"
    require_root
    require_command awk
    require_command ip
    validate_inputs

    if command -v nmcli >/dev/null 2>&1; then
        configure_with_nmcli
    elif command -v netplan >/dev/null 2>&1 || [[ -d "$NETPLAN_DIR" ]]; then
        configure_with_netplan
    else
        echo "Neither NetworkManager nor netplan is available on this host." >&2
        exit 1
    fi

    print_live_state
}

main "$@"