#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-apollo}"
INSTALL_DIR="/usr/local/sbin"
SUDOERS_DIR="/etc/sudoers.d"
SERVICE_SCRIPT="/etc/init.d/codesyscontrol"
LOG_FILE="/var/opt/codesys/codesyscontrol.log"
LOG_TAIL_LINE_COUNT="200"
TAIL_BIN="$(command -v tail || true)"
GIT_USER_NAME="kuriousdesign"
GIT_USER_EMAIL="gardner.761@gmail.com"

usage() {
    cat <<EOF
Usage: sudo ./setup/permissions.sh [--user <name>]

Installs a narrow sudoers rule and root-owned helper commands so the UI can:
- start, stop, and restart codesyscontrol
- tail the approved CODESYS runtime log
- set the target user's global Git username and email

without granting broad sudo access to the application user.

Options:
  --user <name>   Linux user allowed to run the helper commands (default: ${TARGET_USER})
  --help          Show this message

Environment overrides:
  TARGET_USER=<name>
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
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "User not found: $TARGET_USER" >&2
        exit 1
    fi

    if [[ ! -x "$SERVICE_SCRIPT" ]]; then
        echo "CODESYS service script not found or not executable: $SERVICE_SCRIPT" >&2
        exit 1
    fi

    if [[ -z "$TAIL_BIN" || ! -x "$TAIL_BIN" ]]; then
        echo "tail binary not found or not executable" >&2
        exit 1
    fi
}

install_helper_scripts() {
    local action_script="${INSTALL_DIR}/codesys-control-action"
    local log_script="${INSTALL_DIR}/codesys-control-log-tail"

    install -d "$INSTALL_DIR"

    cat >"$action_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

action="\${1:-}"

case "\$action" in
    start|stop|restart)
        exec ${SERVICE_SCRIPT} "\$action"
        ;;
    *)
        echo "Usage: \$(basename "\$0") <start|stop|restart>" >&2
        exit 64
        ;;
esac
EOF

    cat >"$log_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r "${LOG_FILE}" ]]; then
    echo "CODESYS log is unavailable: ${LOG_FILE}" >&2
    exit 1
fi

exec ${TAIL_BIN} -n ${LOG_TAIL_LINE_COUNT} "${LOG_FILE}"
EOF

    chmod 755 "$action_script" "$log_script"
    chown root:root "$action_script" "$log_script"

    echo "Installed helper scripts:"
    echo "  $action_script"
    echo "  $log_script"
}

install_sudoers_rule() {
    local sudoers_file="${SUDOERS_DIR}/${TARGET_USER}-codesys-control"

    install -d "$SUDOERS_DIR"
    cat >"$sudoers_file" <<EOF
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action start
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action stop
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action restart
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-log-tail
${TARGET_USER} ALL=(root) NOPASSWD: ${TAIL_BIN} -n ${LOG_TAIL_LINE_COUNT} ${LOG_FILE}
EOF

    chmod 440 "$sudoers_file"
    chown root:root "$sudoers_file"

    visudo -cf "$sudoers_file"
    echo "Installed sudoers rule at $sudoers_file"
}

configure_git_identity() {
    local user_home

    user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        echo "Unable to determine home directory for $TARGET_USER" >&2
        exit 1
    fi

    runuser -u "$TARGET_USER" -- env HOME="$user_home" git config --global user.name "$GIT_USER_NAME"
    runuser -u "$TARGET_USER" -- env HOME="$user_home" git config --global user.email "$GIT_USER_EMAIL"

    echo "Configured Git identity for $TARGET_USER:"
    echo "  user.name = $GIT_USER_NAME"
    echo "  user.email = $GIT_USER_EMAIL"
}

verify_setup() {
    echo
    echo "Allowed passwordless commands for $TARGET_USER:"
    echo "  sudo -n ${INSTALL_DIR}/codesys-control-action start"
    echo "  sudo -n ${INSTALL_DIR}/codesys-control-action stop"
    echo "  sudo -n ${INSTALL_DIR}/codesys-control-action restart"
    echo "  sudo -n ${INSTALL_DIR}/codesys-control-log-tail"
    echo "  sudo -n ${TAIL_BIN} -n ${LOG_TAIL_LINE_COUNT} ${LOG_FILE}"
}

main() {
    parse_args "$@"
    require_root
    require_command grep
    require_command git
    require_command getent
    require_command runuser
    require_command tail
    require_command visudo
    validate_inputs
    install_helper_scripts
    install_sudoers_rule
    configure_git_identity
    verify_setup
}

main "$@"