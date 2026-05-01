#!/usr/bin/env bash

set -euo pipefail

JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN_FILE="${JOURNALD_DROPIN_DIR}/99-machine-docker.conf"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
CRON_FILE="/etc/cron.d/machine-docker-disk-maintenance"
PRUNE_LOG="/var/log/docker_prune.log"

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

write_if_changed() {
    local target_file="$1"
    local temp_file

    temp_file="$(mktemp)"
    cat >"$temp_file"

    if [[ -f "$target_file" ]] && cmp -s "$temp_file" "$target_file"; then
        rm -f "$temp_file"
        return 1
    fi

    install -Dm644 "$temp_file" "$target_file"
    rm -f "$temp_file"
    return 0
}

configure_journald() {
    mkdir -p "$JOURNALD_DROPIN_DIR"

    if write_if_changed "$JOURNALD_DROPIN_FILE" <<'EOF'; then
[Journal]
SystemMaxUse=500M
EOF
        echo "Configured journald disk cap in $JOURNALD_DROPIN_FILE"
        systemctl restart systemd-journald
    else
        echo "journald disk cap already configured"
    fi

    journalctl --vacuum-size=200M
}

configure_docker_logging() {
    local temp_json
    local target_json

    temp_json="$(mktemp)"
    target_json="$(python3 - "$DOCKER_DAEMON_JSON" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.exists():
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit("/etc/docker/daemon.json must contain a JSON object")

log_opts = data.get("log-opts")
if log_opts is None:
    log_opts = {}
elif not isinstance(log_opts, dict):
    raise SystemExit('Existing "log-opts" value must be a JSON object')

data["log-driver"] = "json-file"
log_opts["max-size"] = "100m"
log_opts["max-file"] = "3"
data["log-opts"] = log_opts

print(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
)"

    printf "%s" "$target_json" >"$temp_json"

    if [[ -f "$DOCKER_DAEMON_JSON" ]] && cmp -s "$temp_json" "$DOCKER_DAEMON_JSON"; then
        rm -f "$temp_json"
        echo "Docker log rotation already configured"
        return
    fi

    if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
        cp "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.bak"
        echo "Backed up existing Docker daemon config to ${DOCKER_DAEMON_JSON}.bak"
    fi

    install -Dm644 "$temp_json" "$DOCKER_DAEMON_JSON"
    rm -f "$temp_json"
    echo "Configured Docker log rotation in $DOCKER_DAEMON_JSON"
    systemctl restart docker
}

configure_cleanup_cron() {
    if write_if_changed "$CRON_FILE" <<EOF; then
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 0 * * 0 root /usr/bin/docker system prune -af --volumes >> $PRUNE_LOG 2>&1
EOF
        echo "Installed weekly Docker cleanup cron at $CRON_FILE"
    else
        echo "Weekly Docker cleanup cron already configured"
    fi
}

run_immediate_cleanup() {
    docker system prune -af --volumes >"$PRUNE_LOG" 2>&1
    echo "Immediate Docker cleanup complete; details written to $PRUNE_LOG"
}

main() {
    require_root
    require_command docker
    require_command journalctl
    require_command python3
    require_command systemctl

    configure_cleanup_cron
    configure_journald
    configure_docker_logging
    run_immediate_cleanup
}

main "$@"