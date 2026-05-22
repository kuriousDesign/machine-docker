#!/usr/bin/env bash

set -euo pipefail

HOSTS_FILE="/etc/hosts"
HOST_IP="127.0.0.1"
MACHINE_ID="${MACHINE_ID:-}"
HOST_PREFIX="${HOST_PREFIX:-apollo}"

usage() {
    cat <<EOF
Usage: sudo ./setup/network-host-alias.sh --machine-id <id> [--host-prefix <prefix>]

Adds or updates a localhost hosts-file alias in the form <prefix>-<machineId>.

Options:
    --machine-id <id>    Machine ID to use, for example 00225 (required)
  --host-prefix <name> Hostname prefix (default: ${HOST_PREFIX})
  --help               Show this message

Environment overrides:
  HOST_PREFIX=<name>
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
            --machine-id)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --machine-id" >&2
                    usage >&2
                    exit 1
                fi
                MACHINE_ID="$2"
                shift 2
                ;;
            --host-prefix)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --host-prefix" >&2
                    usage >&2
                    exit 1
                fi
                HOST_PREFIX="$2"
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
    if [[ -z "$MACHINE_ID" ]]; then
        echo "Missing required --machine-id <id> argument." >&2
        usage >&2
        exit 1
    fi

    if [[ ! "$MACHINE_ID" =~ ^[0-9]+$ ]]; then
        echo "Machine ID must contain only digits. Got: $MACHINE_ID" >&2
        exit 1
    fi

    if [[ ! "$HOST_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        echo "Host prefix must be alphanumeric or hyphenated. Got: $HOST_PREFIX" >&2
        exit 1
    fi

    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "Hosts file not found: $HOSTS_FILE" >&2
        exit 1
    fi
}

update_hosts_file() {
    local alias_name
    local temp_file
    local existing_ip

    alias_name="${HOST_PREFIX}-${MACHINE_ID}"
    temp_file="$(mktemp)"
    existing_ip="$(awk -v alias_name="$alias_name" '
        $0 !~ /^[[:space:]]*#/ {
            for (i = 2; i <= NF; i++) {
                if ($i == alias_name) {
                    print $1
                    exit
                }
            }
        }
    ' "$HOSTS_FILE")"

    awk -v alias_name="$alias_name" '
        $0 ~ /^[[:space:]]*#/ {
            print
            next
        }

        {
            keep_count = 0
            for (i = 2; i <= NF; i++) {
                if ($i != alias_name) {
                    keep[++keep_count] = $i
                }
            }

            if (keep_count == 0) {
                if (NF >= 1 && $1 !~ /^[[:space:]]*$/) {
                    next
                }
                print
                next
            }

            printf "%s", $1
            for (i = 1; i <= keep_count; i++) {
                printf " %s", keep[i]
                delete keep[i]
            }
            printf "\n"
        }
    ' "$HOSTS_FILE" >"$temp_file"

    printf "%s %s\n" "$HOST_IP" "$alias_name" >>"$temp_file"
    install -m 644 "$temp_file" "$HOSTS_FILE"
    rm -f "$temp_file"

    if [[ "$existing_ip" == "$HOST_IP" ]]; then
        echo "Hosts entry already configured: ${HOST_IP} ${alias_name}"
    elif [[ -n "$existing_ip" ]]; then
        echo "Updated hosts entry: ${existing_ip} ${alias_name} -> ${HOST_IP} ${alias_name}"
    else
        echo "Added hosts entry: ${HOST_IP} ${alias_name}"
    fi
}

main() {
    parse_args "$@"
    require_root
    require_command awk
    require_command install
    require_command mktemp
    validate_inputs
    update_hosts_file
}

main "$@"