#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-kiosk}"
MACHINE_ID="${MACHINE_ID:-00225}"
HOST_PREFIX="${HOST_PREFIX:-apollo}"
HOST_IP="${HOST_IP:-192.168.102.1}"
UI_URL="${UI_URL:-}"
DISPLAY_NAME="${DISPLAY_NAME:-:0}"
DUMMY_DISPLAY_MODE="${DUMMY_DISPLAY_MODE:-auto}"
DISPLAY_ROTATION="${DISPLAY_ROTATION:-normal}"

LIGHTDM_CONF_DIR="/etc/lightdm/lightdm.conf.d"
LIGHTDM_CONF_FILE="${LIGHTDM_CONF_DIR}/50-machine-kiosk.conf"
HOSTS_FILE="/etc/hosts"
XORG_CONF_DIR="/etc/X11/xorg.conf.d"
DUMMY_XORG_CONF_FILE="${XORG_CONF_DIR}/20-kiosk-dummy.conf"
CHROMIUM_WRAPPER_PATH="/usr/local/bin/chromium-browser"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_ROOT_CERT_FALLBACK="${REPO_ROOT}/certs/caddy-local-root.crt"

DISPLAY_BACKEND="unknown"
LOGINCTL_REPORT=""
CHROMIUM_PROCESS_LINE=""

usage() {
    cat <<EOF
Usage: sudo ./setup/kiosk-ui-client.sh [options]

Sets up a persistent X11 kiosk client using LightDM autologin, Openbox, and Chromium.

Options:
  --user <linux-user>           Kiosk user account (default: ${TARGET_USER})
  --machine-id <id>            Machine ID used to derive the hostname (default: ${MACHINE_ID})
  --host-prefix <prefix>       Hostname prefix (default: ${HOST_PREFIX})
  --host-ip <ipv4>             IP address mapped in /etc/hosts (default: ${HOST_IP})
    --url <http-url>             URL to open in Chromium (default: http://<prefix>-<machine-id>:3000/)
  --display <display>          X11 display name to target (default: ${DISPLAY_NAME})
  --dummy-display <mode>       One of auto, always, never (default: ${DUMMY_DISPLAY_MODE})
    --portrait                   Rotate the kiosk display into portrait mode
  --help                       Show this message

Environment overrides:
  TARGET_USER=<linux-user>
  MACHINE_ID=<id>
  HOST_PREFIX=<prefix>
  HOST_IP=<ipv4>
  UI_URL=<http-url>
  DISPLAY_NAME=<display>
  DUMMY_DISPLAY_MODE=<auto|always|never>
    DISPLAY_ROTATION=<normal|right>
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
                TARGET_USER="$2"
                shift 2
                ;;
            --machine-id)
                MACHINE_ID="$2"
                shift 2
                ;;
            --host-prefix)
                HOST_PREFIX="$2"
                shift 2
                ;;
            --host-ip)
                HOST_IP="$2"
                shift 2
                ;;
            --url)
                UI_URL="$2"
                shift 2
                ;;
            --display)
                DISPLAY_NAME="$2"
                shift 2
                ;;
            --dummy-display)
                DUMMY_DISPLAY_MODE="$2"
                shift 2
                ;;
            --portrait)
                DISPLAY_ROTATION="right"
                shift 1
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
    if [[ ! "$MACHINE_ID" =~ ^[0-9]+$ ]]; then
        echo "Machine ID must contain only digits. Got: $MACHINE_ID" >&2
        exit 1
    fi

    if [[ ! "$HOST_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        echo "Host prefix must be alphanumeric or hyphenated. Got: $HOST_PREFIX" >&2
        exit 1
    fi

    if [[ ! "$HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Host IP must be an IPv4 address. Got: $HOST_IP" >&2
        exit 1
    fi

    if [[ "$DUMMY_DISPLAY_MODE" != "auto" && "$DUMMY_DISPLAY_MODE" != "always" && "$DUMMY_DISPLAY_MODE" != "never" ]]; then
        echo "--dummy-display must be one of auto, always, never. Got: $DUMMY_DISPLAY_MODE" >&2
        exit 1
    fi

    if [[ "$DISPLAY_ROTATION" != "normal" && "$DISPLAY_ROTATION" != "right" ]]; then
        echo "DISPLAY_ROTATION must be one of normal or right. Got: $DISPLAY_ROTATION" >&2
        exit 1
    fi

    if [[ -z "$UI_URL" ]]; then
        UI_URL="http://${HOST_PREFIX}-${MACHINE_ID}:3000/"
    fi

    if [[ ! "$UI_URL" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "URL must start with http:// or https:// and contain no spaces. Got: $UI_URL" >&2
        exit 1
    fi
}

resolve_user_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

has_real_display_hardware() {
    local status_file

    for status_file in /sys/class/drm/*/status; do
        if [[ -f "$status_file" ]] && [[ "$(<"$status_file")" == "connected" ]]; then
            return 0
        fi
    done

    return 1
}

prepare_apt() {
    export DEBIAN_FRONTEND=noninteractive

    printf 'lightdm shared/default-x-display-manager select lightdm\n' | debconf-set-selections || true
    printf 'lightdm lightdm/default-display-manager select lightdm\n' | debconf-set-selections || true
}

install_packages() {
    local common_packages=(
        curl
        dbus-x11
        libnss3-tools
        lightdm
        lightdm-gtk-greeter
        openbox
        unclutter
        xauth
        xinit
        x11-xserver-utils
        xserver-xorg-core
        xserver-xorg-input-libinput
    )

    prepare_apt
    apt-get update
    apt-get install -y --no-install-recommends "${common_packages[@]}"

    if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
        if ! apt-get install -y --no-install-recommends chromium-browser; then
            apt-get install -y --no-install-recommends chromium
        fi
    fi
}

ensure_chromium_browser_launcher() {
    local chromium_real_bin=""

    if command -v chromium-browser >/dev/null 2>&1; then
        return
    fi

    if command -v chromium >/dev/null 2>&1; then
        chromium_real_bin="$(command -v chromium)"
    fi

    if [[ -z "$chromium_real_bin" ]]; then
        echo "Unable to find Chromium after package installation." >&2
        exit 1
    fi

    cat >"$CHROMIUM_WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
exec ${chromium_real_bin} "\$@"
EOF

    chmod 755 "$CHROMIUM_WRAPPER_PATH"
}

ensure_kiosk_user() {
    local group_name
    local user_home
    local supplemental_group

    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$TARGET_USER"
        passwd -l "$TARGET_USER" >/dev/null 2>&1 || true
        echo "Created kiosk user: $TARGET_USER"
    else
        echo "Using existing kiosk user: $TARGET_USER"
    fi

    for supplemental_group in audio input render video; do
        if getent group "$supplemental_group" >/dev/null 2>&1; then
            usermod -a -G "$supplemental_group" "$TARGET_USER"
        fi
    done

    group_name="$(id -gn "$TARGET_USER")"
    user_home="$(resolve_user_home)"

    install -d -m 755 -o "$TARGET_USER" -g "$group_name" "$user_home/.config/openbox"
}

configure_hosts_alias() {
    local alias_name
    local temp_file

    alias_name="${HOST_PREFIX}-${MACHINE_ID}"
    temp_file="$(mktemp)"

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

    printf '%s %s\n' "$HOST_IP" "$alias_name" >>"$temp_file"
    install -m 644 "$temp_file" "$HOSTS_FILE"
    rm -f "$temp_file"

    echo "Configured hostname alias: ${alias_name} -> ${HOST_IP}"
}

configure_dummy_display_if_needed() {
    install -d -m 755 "$XORG_CONF_DIR"

    if [[ "$DUMMY_DISPLAY_MODE" == "always" ]]; then
        DISPLAY_BACKEND="dummy"
    elif has_real_display_hardware; then
        DISPLAY_BACKEND="real local display hardware"
        rm -f "$DUMMY_XORG_CONF_FILE"
        return
    elif [[ "$DUMMY_DISPLAY_MODE" == "auto" ]]; then
        DISPLAY_BACKEND="Xorg dummy display"
    else
        echo "No connected local display hardware was detected." >&2
        echo "Provide a dummy HDMI/display adapter or rerun with --dummy-display auto to install an Xorg dummy display." >&2
        exit 1
    fi

    apt-get install -y --no-install-recommends xserver-xorg-video-dummy

    cat >"$DUMMY_XORG_CONF_FILE" <<'EOF'
Section "Monitor"
    Identifier "Monitor0"
    HorizSync 28.0-80.0
    VertRefresh 48.0-75.0
    Modeline "1920x1080" 172.80 1920 2040 2248 2576 1080 1081 1084 1118
    Option "PreferredMode" "1920x1080"
EndSection

Section "Device"
    Identifier "DummyDevice"
    Driver "dummy"
    VideoRam 256000
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "DummyDevice"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "Layout0"
    Screen "Screen0"
EndSection
EOF

    echo "Configured Xorg dummy display at $DUMMY_XORG_CONF_FILE"
}

configure_lightdm_autologin() {
    local user_home
    local group_name
    local dmrc_file
    local xsession_file

    user_home="$(resolve_user_home)"
    group_name="$(id -gn "$TARGET_USER")"
    dmrc_file="${user_home}/.dmrc"
    xsession_file="${user_home}/.xsession"

    install -d -m 755 "$LIGHTDM_CONF_DIR"

    cat >"$LIGHTDM_CONF_FILE" <<EOF
[Seat:*]
autologin-user=${TARGET_USER}
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
EOF

    cat >"$dmrc_file" <<EOF
[Desktop]
Session=openbox
EOF

    cat >"$xsession_file" <<EOF
#!/usr/bin/env bash
export DISPLAY=${DISPLAY_NAME}
export XAUTHORITY=${user_home}/.Xauthority
exec openbox-session
EOF

    chmod 644 "$dmrc_file"
    chmod 755 "$xsession_file"
    chown "$TARGET_USER":"$group_name" "$dmrc_file" "$xsession_file"

    printf '/usr/sbin/lightdm\n' >/etc/X11/default-display-manager
    systemctl set-default graphical.target
    systemctl enable lightdm

    if systemctl list-unit-files gdm3.service >/dev/null 2>&1; then
        systemctl disable gdm3 >/dev/null 2>&1 || true
    fi

    if systemctl list-unit-files sddm.service >/dev/null 2>&1; then
        systemctl disable sddm >/dev/null 2>&1 || true
    fi
}

configure_openbox_autostart() {
    local user_home
    local group_name
    local autostart_file

    user_home="$(resolve_user_home)"
    group_name="$(id -gn "$TARGET_USER")"
    autostart_file="${user_home}/.config/openbox/autostart"

    cat >"$autostart_file" <<EOF
#!/usr/bin/env bash
export DISPLAY=${DISPLAY_NAME}
export XAUTHORITY=${user_home}/.Xauthority

if command -v xrandr >/dev/null 2>&1; then
    kiosk_output="\$(xrandr --display ${DISPLAY_NAME} --query 2>/dev/null | awk '/ connected/{print \$1; exit}')"

    if [[ -n "\$kiosk_output" ]]; then
        xrandr --display ${DISPLAY_NAME} --output "\$kiosk_output" --rotate ${DISPLAY_ROTATION} || true
    fi
fi

xset s off
xset -dpms
xset s noblank
unclutter -idle 1 &

chromium-browser \\
  --kiosk \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --check-for-update-interval=31536000 \\
  ${UI_URL}
EOF

    chmod 755 "$autostart_file"
    chown "$TARGET_USER":"$group_name" "$autostart_file"
}

resolve_caddy_root_cert() {
    local live_cert_path="/var/lib/docker/volumes/machine-docker_caddy_data/_data/caddy/pki/authorities/local/root.crt"

    if [[ -f "$live_cert_path" ]]; then
        printf '%s\n' "$live_cert_path"
        return
    fi

    if [[ -f "$CADDY_ROOT_CERT_FALLBACK" ]]; then
        printf '%s\n' "$CADDY_ROOT_CERT_FALLBACK"
        return
    fi

    printf '%s\n' ""
}

import_caddy_root_certificate() {
    local user_home
    local group_name
    local cert_path
    local staged_cert_path
    local nssdb_dir
    local imported_any="false"
    local -a nssdb_dirs=()

    cert_path="$(resolve_caddy_root_cert)"
    if [[ -z "$cert_path" ]]; then
        echo "Skipping Chromium trust import: no Caddy root certificate found." >&2
        return
    fi

    user_home="$(resolve_user_home)"
    group_name="$(id -gn "$TARGET_USER")"
    staged_cert_path="${user_home}/.config/caddy-local-root.crt"
    nssdb_dirs=(
        "${user_home}/.pki/nssdb"
        "${user_home}/snap/chromium/current/.pki/nssdb"
    )

    install -d -m 755 -o "$TARGET_USER" -g "$group_name" "${user_home}/.config"
    install -m 644 -o "$TARGET_USER" -g "$group_name" "$cert_path" "$staged_cert_path"

    for nssdb_dir in "${nssdb_dirs[@]}"; do
        install -d -m 700 -o "$TARGET_USER" -g "$group_name" "$nssdb_dir"

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

        imported_any="true"
    done

    if [[ "$imported_any" == "true" ]]; then
        echo "Imported Caddy root certificate into Chromium NSS trust stores from ${cert_path}"
    fi
}

restart_display_manager() {
    if systemctl is-active --quiet lightdm; then
        systemctl restart lightdm
    else
        systemctl start lightdm
    fi
}

capture_loginctl_report() {
    local sessions
    local session_id

    LOGINCTL_REPORT="$(loginctl list-sessions --no-legend 2>/dev/null || true)"
    sessions="$(awk '$3 == "'"$TARGET_USER"'" { print $1 }' <<<"$LOGINCTL_REPORT" || true)"

    for session_id in $sessions; do
        LOGINCTL_REPORT+=$'\n'
        LOGINCTL_REPORT+="$(loginctl show-session "$session_id" -p Id -p Name -p User -p State -p Class -p Type -p Seat -p Display -p Remote 2>/dev/null || true)"
    done
}

wait_for_kiosk_session() {
    local attempt
    local session_found=""

    for attempt in $(seq 1 20); do
        capture_loginctl_report
        session_found="$(grep -E "User=.*${TARGET_USER}|${TARGET_USER}" <<<"$LOGINCTL_REPORT" || true)"
        if [[ -n "$session_found" ]] && grep -q 'Type=x11' <<<"$LOGINCTL_REPORT"; then
            return
        fi
        sleep 2
    done
}

wait_for_chromium_process() {
    local attempt

    for attempt in $(seq 1 20); do
        CHROMIUM_PROCESS_LINE="$(pgrep -a -u "$TARGET_USER" -f 'chromium-browser|chromium' | grep -- '--kiosk' | head -n 1 || true)"
        if [[ -n "$CHROMIUM_PROCESS_LINE" ]]; then
            return
        fi
        sleep 2
    done
}

verify_setup() {
    local user_home
    local autostart_file

    user_home="$(resolve_user_home)"
    autostart_file="${user_home}/.config/openbox/autostart"

    wait_for_kiosk_session
    wait_for_chromium_process
    capture_loginctl_report

    echo
    echo "Final autostart file contents:"
    cat "$autostart_file"

    echo
    echo "LightDM autologin config:"
    cat "$LIGHTDM_CONF_FILE"

    echo
    echo "loginctl output:"
    printf '%s\n' "$LOGINCTL_REPORT"

    echo
    echo "Running Chromium command line:"
    if [[ -n "$CHROMIUM_PROCESS_LINE" ]]; then
        printf '%s\n' "$CHROMIUM_PROCESS_LINE"
    else
        echo "Chromium is not running as ${TARGET_USER} yet." >&2
    fi

    echo
    echo "Display backend: ${DISPLAY_BACKEND}"

    echo
    echo "Verifying browser target URL with curl: ${UI_URL}"
    curl --fail --silent --show-error "$UI_URL" >/dev/null
    echo "curl verification succeeded"

    if [[ -z "$CHROMIUM_PROCESS_LINE" || "$CHROMIUM_PROCESS_LINE" != *"--kiosk"* || "$CHROMIUM_PROCESS_LINE" != *"${UI_URL}"* ]]; then
        echo "Chromium verification did not find the expected --kiosk process and URL." >&2
        exit 1
    fi

    echo
    echo "Persistent kiosk setup is installed. The LightDM autologin and Openbox autostart files survive reboot."
}

main() {
    parse_args "$@"
    require_root
    require_command apt-get
    require_command awk
    require_command curl
    require_command debconf-set-selections
    require_command getent
    require_command install
    require_command loginctl
    require_command mktemp
    require_command pgrep
    require_command sleep
    require_command systemctl
    require_command useradd
    validate_inputs
    install_packages
    ensure_chromium_browser_launcher
    ensure_kiosk_user
    configure_hosts_alias
    configure_dummy_display_if_needed
    configure_lightdm_autologin
    configure_openbox_autostart
    import_caddy_root_certificate
    restart_display_manager
    verify_setup
}

main "$@"