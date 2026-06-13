#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-apollo}"
UI_URL="${UI_URL:-}"
BROWSER_BIN="${BROWSER_BIN:-}"
HOST_ALIAS="${HOST_ALIAS:-}"
HOST_IP="${HOST_IP:-}"
AUTOSTART_FILE_NAME="machine-ui-chrome.desktop"
DESKTOP_SHORTCUT_FILE_NAME="Machine UI Chrome.desktop"
HOSTS_FILE="/etc/hosts"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_ROOT_CERT_PATH="${REPO_ROOT}/certs/caddy-local-root.crt"

usage() {
    cat <<EOF
Usage: sudo ./setup/chrome-ui-autostart.sh --url <ui-url> [--user <linux-user>] [--browser <path>] [--host-alias <hostname> --host-ip <ipv4>]

Installs a per-user desktop autostart entry and desktop shortcut that launch
Chrome to the machine UI.

Options:
  --url <ui-url>       UI URL to open at login, for example http://apollo-00251:3000 (required)
  --user <linux-user>  Linux account that should receive the autostart entry (default: ${TARGET_USER})
  --browser <path>     Browser executable to launch (default: auto-detect Chrome/Chromium)
    --host-alias <name>  Optional hostname to add to /etc/hosts, for example apollo-00225
    --host-ip <ipv4>     IPv4 address paired with --host-alias, for example 192.168.102.1
  --help               Show this message

Environment overrides:
  TARGET_USER=<linux-user>
  UI_URL=<ui-url>
  BROWSER_BIN=<path>
    HOST_ALIAS=<hostname>
    HOST_IP=<ipv4>
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
            --url)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --url" >&2
                    usage >&2
                    exit 1
                fi
                UI_URL="$2"
                shift 2
                ;;
            --user)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --user" >&2
                    usage >&2
                    exit 1
                fi
                TARGET_USER="$2"
                shift 2
                ;;
            --browser)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --browser" >&2
                    usage >&2
                    exit 1
                fi
                BROWSER_BIN="$2"
                shift 2
                ;;
            --host-alias)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --host-alias" >&2
                    usage >&2
                    exit 1
                fi
                HOST_ALIAS="$2"
                shift 2
                ;;
            --host-ip)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --host-ip" >&2
                    usage >&2
                    exit 1
                fi
                HOST_IP="$2"
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

resolve_user_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

resolve_desktop_dir() {
    local user_home
    local user_dirs_file
    local configured_dir

    user_home="$(resolve_user_home)"
    user_dirs_file="${user_home}/.config/user-dirs.dirs"

    if [[ -f "$user_dirs_file" ]]; then
        configured_dir="$({
            grep '^XDG_DESKTOP_DIR=' "$user_dirs_file" || true
        } | tail -n 1)"
        configured_dir="${configured_dir#XDG_DESKTOP_DIR=}"
        configured_dir="${configured_dir//\"/}"
        configured_dir="${configured_dir//\$HOME/$user_home}"

        if [[ -n "$configured_dir" ]]; then
            printf '%s\n' "$configured_dir"
            return
        fi
    fi

    printf '%s/Desktop\n' "$user_home"
}

detect_browser() {
    local candidate

    if [[ -n "$BROWSER_BIN" ]]; then
        return
    fi

    for candidate in google-chrome-stable google-chrome chromium-browser chromium; do
        if command -v "$candidate" >/dev/null 2>&1; then
            BROWSER_BIN="$(command -v "$candidate")"
            return
        fi
    done

    echo "Unable to find a supported Chrome/Chromium binary." >&2
    exit 1
}

validate_inputs() {
    local user_home

    if [[ -z "$UI_URL" ]]; then
        echo "Missing required --url <ui-url> argument." >&2
        usage >&2
        exit 1
    fi

    if [[ ! "$UI_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "UI URL must start with http:// or https:// and contain no spaces. Got: $UI_URL" >&2
        exit 1
    fi

    user_home="$(resolve_user_home)"
    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "Unable to determine home directory for $TARGET_USER" >&2
        exit 1
    fi

    if [[ ! -x "$BROWSER_BIN" ]]; then
        echo "Browser executable not found or not executable: $BROWSER_BIN" >&2
        exit 1
    fi

    if [[ -n "$HOST_ALIAS" || -n "$HOST_IP" ]]; then
        if [[ -z "$HOST_ALIAS" || -z "$HOST_IP" ]]; then
            echo "--host-alias and --host-ip must be provided together." >&2
            exit 1
        fi

        if [[ ! "$HOST_ALIAS" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
            echo "Host alias must be alphanumeric, dot, or hyphen. Got: $HOST_ALIAS" >&2
            exit 1
        fi

        if [[ ! "$HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "Host IP must be an IPv4 address. Got: $HOST_IP" >&2
            exit 1
        fi
    fi

    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "Hosts file not found: $HOSTS_FILE" >&2
        exit 1
    fi
}

configure_hosts_alias() {
    local temp_file

    if [[ -z "$HOST_ALIAS" || -z "$HOST_IP" ]]; then
        return
    fi

    temp_file="$(mktemp)"

    awk -v host_alias="$HOST_ALIAS" '
        $0 ~ /^[[:space:]]*#/ {
            print
            next
        }

        {
            keep_count = 0
            for (i = 2; i <= NF; i++) {
                if ($i != host_alias) {
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

    printf "%s %s\n" "$HOST_IP" "$HOST_ALIAS" >>"$temp_file"
    install -m 644 "$temp_file" "$HOSTS_FILE"
    rm -f "$temp_file"

    echo "Configured hosts entry: ${HOST_IP} ${HOST_ALIAS}"
}

import_caddy_root_certificate() {
    local user_home
    local target_group
    local staged_cert_path
    local nssdb_dir

    if [[ ! -f "$CADDY_ROOT_CERT_PATH" ]]; then
        echo "Skipping certificate import: missing ${CADDY_ROOT_CERT_PATH}" >&2
        return
    fi

    if ! command -v certutil >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends libnss3-tools
    fi

    user_home="$(resolve_user_home)"
    target_group="$(id -gn "$TARGET_USER")"
    staged_cert_path="${user_home}/.config/caddy-local-root.crt"

    install -d -m 755 -o "$TARGET_USER" -g "$target_group" "${user_home}/.config"
    install -d -m 755 -o "$TARGET_USER" -g "$target_group" "${user_home}/.pki"
    install -m 644 -o "$TARGET_USER" -g "$target_group" "$CADDY_ROOT_CERT_PATH" "$staged_cert_path"

    for nssdb_dir in \
        "${user_home}/.pki/nssdb" \
        "${user_home}/snap/chromium/current/.pki/nssdb" \
        "${user_home}/snap/google-chrome/current/.pki/nssdb"; do
        install -d -m 700 -o "$TARGET_USER" -g "$target_group" "$nssdb_dir"

        if ! sudo -u "$TARGET_USER" certutil -d "sql:${nssdb_dir}" -L >/dev/null 2>&1; then
            sudo -u "$TARGET_USER" certutil -d "sql:${nssdb_dir}" -N --empty-password
        fi

        sudo -u "$TARGET_USER" certutil -d "sql:${nssdb_dir}" -D -n "Caddy Local Authority" >/dev/null 2>&1 || true
        sudo -u "$TARGET_USER" certutil \
            -d "sql:${nssdb_dir}" \
            -A \
            -n "Caddy Local Authority" \
            -t "C,," \
            -i "$staged_cert_path"
    done

    echo "Imported Caddy root certificate for ${TARGET_USER}"
}

install_autostart_entry() {
    local user_home
    local target_group
    local autostart_dir
    local desktop_file
    local temp_file

    user_home="$(resolve_user_home)"
    target_group="$(id -gn "$TARGET_USER")"
    autostart_dir="${user_home}/.config/autostart"
    desktop_file="${autostart_dir}/${AUTOSTART_FILE_NAME}"
    temp_file="$(mktemp)"

    install -d -m 755 -o "$TARGET_USER" -g "$target_group" "$autostart_dir"

    cat >"$temp_file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Machine UI Chrome
Comment=Launch the machine UI in Chrome at login
Exec=${BROWSER_BIN} --no-first-run --no-default-browser-check --password-store=basic --disable-session-crashed-bubble --disable-features=ChromeWhatsNewUI --noerrdialogs --test-type --start-fullscreen --new-window ${UI_URL}
Terminal=false
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF

    if [[ -f "$desktop_file" ]] && cmp -s "$temp_file" "$desktop_file"; then
        rm -f "$temp_file"
        echo "Chrome UI autostart already configured for $TARGET_USER at $desktop_file"
        return
    fi

    install -m 644 -o "$TARGET_USER" -g "$target_group" "$temp_file" "$desktop_file"
    rm -f "$temp_file"

    echo "Installed Chrome UI autostart for $TARGET_USER"
    echo "  Browser: $BROWSER_BIN"
    echo "  URL: $UI_URL"
    echo "  Desktop entry: $desktop_file"
}

install_desktop_shortcut() {
    local user_home
    local target_group
    local desktop_dir
    local desktop_file
    local temp_file

    user_home="$(resolve_user_home)"
    target_group="$(id -gn "$TARGET_USER")"
    desktop_dir="$(resolve_desktop_dir)"
    desktop_file="${desktop_dir}/${DESKTOP_SHORTCUT_FILE_NAME}"
    temp_file="$(mktemp)"

    install -d -m 755 -o "$TARGET_USER" -g "$target_group" "$desktop_dir"

    cat >"$temp_file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Machine UI Chrome
Comment=Launch the machine UI in Chrome
Exec=${BROWSER_BIN} --no-first-run --no-default-browser-check --password-store=basic --disable-session-crashed-bubble --disable-features=ChromeWhatsNewUI --noerrdialogs --test-type --start-fullscreen --new-window ${UI_URL}
Terminal=false
Icon=google-chrome
StartupNotify=false
EOF

    if [[ -f "$desktop_file" ]] && cmp -s "$temp_file" "$desktop_file"; then
        rm -f "$temp_file"
        echo "Chrome UI desktop shortcut already configured for $TARGET_USER at $desktop_file"
        return
    fi

    install -m 755 -o "$TARGET_USER" -g "$target_group" "$temp_file" "$desktop_file"
    rm -f "$temp_file"

    echo "Installed Chrome UI desktop shortcut for $TARGET_USER"
    echo "  Shortcut: $desktop_file"
}

main() {
    parse_args "$@"
    require_root
    require_command cmp
    require_command getent
    require_command grep
    require_command id
    require_command install
    require_command mktemp
    require_command awk
    require_command tail
    detect_browser
    validate_inputs
    configure_hosts_alias
    import_caddy_root_certificate
    install_autostart_entry
    install_desktop_shortcut
}

main "$@"