#!/usr/bin/env bash

set -euo pipefail

DISABLE_SNAPD="${DISABLE_SNAPD:-0}"
DISABLE_REMOTE_ACCESS="${DISABLE_REMOTE_ACCESS:-0}"
APT_PERIODIC_CONF_DIR="/etc/apt/apt.conf.d"
APT_PERIODIC_CONF_FILE="${APT_PERIODIC_CONF_DIR}/99-machine-offline"
MOTD_NEWS_FILE="/etc/default/motd-news"

usage() {
    cat <<EOF
Usage: sudo ./setup/offline-startup-hardening.sh [options]

Disables common startup waits and background update/reporting services that are
noisy or slow on air-gapped kiosk-style machines.

By default this script will:
- mask NetworkManager and systemd wait-online services
- disable apt periodic update timers and unattended-upgrades
- disable Ubuntu Pro timer hooks and motd news fetches
- disable apport, kerneloops, and fwupd refresh jobs

Options:
  --disable-snapd           Also disable snapd services and sockets
  --disable-remote-access   Also disable rustdesk and gnome-remote-desktop
  --help                    Show this message

Environment overrides:
  DISABLE_SNAPD=1
  DISABLE_REMOTE_ACCESS=1

Notes:
- local Docker containers and CODESYS services are left enabled
- this script does not remove packages; it only disables or masks services
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
            --disable-snapd)
                DISABLE_SNAPD="1"
                shift 1
                ;;
            --disable-remote-access)
                DISABLE_REMOTE_ACCESS="1"
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
    if [[ "$DISABLE_SNAPD" != "0" && "$DISABLE_SNAPD" != "1" ]]; then
        echo "DISABLE_SNAPD must be 0 or 1. Got: $DISABLE_SNAPD" >&2
        exit 1
    fi

    if [[ "$DISABLE_REMOTE_ACCESS" != "0" && "$DISABLE_REMOTE_ACCESS" != "1" ]]; then
        echo "DISABLE_REMOTE_ACCESS must be 0 or 1. Got: $DISABLE_REMOTE_ACCESS" >&2
        exit 1
    fi
}

unit_exists() {
    local unit_name="$1"

    systemctl list-unit-files "$unit_name" --no-legend 2>/dev/null | awk 'NF > 0 { found = 1 } END { exit(found ? 0 : 1) }'
}

disable_units() {
    local unit_name

    for unit_name in "$@"; do
        if unit_exists "$unit_name"; then
            systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
            echo "Disabled $unit_name"
        fi
    done
}

mask_units() {
    local unit_name

    for unit_name in "$@"; do
        if unit_exists "$unit_name"; then
            systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
            systemctl mask "$unit_name" >/dev/null 2>&1 || true
            echo "Masked $unit_name"
        fi
    done
}

configure_apt_periodic() {
    install -d -m 755 "$APT_PERIODIC_CONF_DIR"

    cat >"$APT_PERIODIC_CONF_FILE" <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    echo "Wrote $APT_PERIODIC_CONF_FILE"
}

configure_motd_news() {
    cat >"$MOTD_NEWS_FILE" <<'EOF'
ENABLED=0
EOF

    echo "Wrote $MOTD_NEWS_FILE"
}

disable_boot_waits() {
    mask_units \
        NetworkManager-wait-online.service \
        systemd-networkd-wait-online.service
}

disable_background_updates() {
    configure_apt_periodic
    configure_motd_news

    mask_units \
        apt-daily.service \
        apt-daily-upgrade.service

    disable_units \
        apt-daily.timer \
        apt-daily-upgrade.timer \
        unattended-upgrades.service \
        ua-reboot-cmds.service \
        ua-timer.timer
}

disable_reporting_jobs() {
    disable_units \
        apport.service \
        kerneloops.service \
        fwupd-refresh.timer \
        fwupd-refresh.service
}

disable_snapd_if_requested() {
    if [[ "$DISABLE_SNAPD" != "1" ]]; then
        return
    fi

    mask_units \
        snapd.service \
        snapd.socket \
        snapd.seeded.service \
        snapd.autoimport.service \
        snapd.core-fixup.service \
        snapd.recovery-chooser-trigger.service

    disable_units snapd.snap-repair.timer
}

disable_remote_access_if_requested() {
    if [[ "$DISABLE_REMOTE_ACCESS" != "1" ]]; then
        return
    fi

    disable_units \
        rustdesk.service \
        gnome-remote-desktop.service
}

print_summary() {
    echo
    echo "Offline startup hardening complete."
    echo "Kept enabled: docker.service, containerd.service, codesyscontrol.service, codesysedge.service"
    if [[ "$DISABLE_SNAPD" == "1" ]]; then
        echo "snapd has been disabled; do not use this if the machine still depends on snap-managed software"
    fi
    if [[ "$DISABLE_REMOTE_ACCESS" == "1" ]]; then
        echo "Remote desktop services have been disabled"
    fi
}

main() {
    parse_args "$@"
    require_root
    require_command awk
    require_command id
    require_command install
    require_command systemctl
    validate_inputs
    disable_boot_waits
    disable_background_updates
    disable_reporting_jobs
    disable_snapd_if_requested
    disable_remote_access_if_requested
    print_summary
}

main "$@"