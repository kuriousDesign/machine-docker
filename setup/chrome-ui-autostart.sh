#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-apollo}"
UI_URL="${UI_URL:-}"
BROWSER_BIN="${BROWSER_BIN:-}"
AUTOSTART_FILE_NAME="machine-ui-chrome.desktop"
DESKTOP_SHORTCUT_FILE_NAME="Machine UI Chrome.desktop"

usage() {
    cat <<EOF
Usage: sudo ./setup/chrome-ui-autostart.sh --url <ui-url> [--user <linux-user>] [--browser <path>]

Installs a per-user desktop autostart entry and desktop shortcut that launch
Chrome to the machine UI.

Options:
  --url <ui-url>       UI URL to open at login, for example http://apollo-00251:3000 (required)
  --user <linux-user>  Linux account that should receive the autostart entry (default: ${TARGET_USER})
  --browser <path>     Browser executable to launch (default: auto-detect Chrome/Chromium)
  --help               Show this message

Environment overrides:
  TARGET_USER=<linux-user>
  UI_URL=<ui-url>
  BROWSER_BIN=<path>
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
    require_command tail
    detect_browser
    validate_inputs
    install_autostart_entry
    install_desktop_shortcut
}

main "$@"