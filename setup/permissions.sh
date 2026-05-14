#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${TARGET_USER:-}"
INSTALL_DIR="/usr/local/sbin"
SUDOERS_DIR="/etc/sudoers.d"
SERVICE_SCRIPT="/etc/init.d/codesyscontrol"
LOG_FILE="/var/opt/codesys/codesyscontrol.log"
LOG_TAIL_LINE_COUNT="200"
TAIL_BIN="$(command -v tail || true)"
UI_REPO_DIR="${UI_REPO_DIR:-/opt/repos/machine-ui-heroui-shadcn}"
GIT_USER_NAME="kuriousdesign"
GIT_USER_EMAIL="gardner.761@gmail.com"

usage() {
    cat <<EOF
Usage: sudo ./setup/permissions.sh [--user <name>]

Installs a narrow sudoers rule and root-owned helper commands so the UI can:
- start, stop, and restart codesyscontrol
- tail the approved CODESYS runtime log
- reset the generated machine-ui build cache directory when container runs leave it root-owned
- set the target user's global Git username and email

without granting broad sudo access to the application user.

Options:
    --user <name>   Linux user allowed to run the helper commands
  --help          Show this message

Environment overrides:
  TARGET_USER=<name>
    UI_REPO_DIR=<path>

If --user and TARGET_USER are omitted, the script uses the invoking sudo user.
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

resolve_target_user() {
    if [[ -n "$TARGET_USER" ]]; then
        return
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
        return
    fi

    echo "Unable to determine the target user automatically. Re-run with --user <name> or TARGET_USER=<name>." >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Missing value for --user" >&2
                    usage >&2
                    exit 1
                fi
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

    if [[ ! -d "$UI_REPO_DIR" ]]; then
        echo "machine-ui repo directory not found: $UI_REPO_DIR" >&2
        exit 1
    fi
}

install_helper_scripts() {
    local action_script="${INSTALL_DIR}/codesys-control-action"
    local log_script="${INSTALL_DIR}/codesys-control-log-tail"
    local ui_reset_script="${INSTALL_DIR}/machine-ui-reset-build-cache"
    local target_group

    target_group="$(id -gn "$TARGET_USER")"

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

    cat >"$ui_reset_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

rm -rf "${UI_REPO_DIR}/.next"
install -d -m 775 -o "${TARGET_USER}" -g "${target_group}" "${UI_REPO_DIR}/.next"

echo "Reset machine-ui build cache at ${UI_REPO_DIR}/.next for ${TARGET_USER}:${target_group}"
EOF

    chmod 755 "$action_script" "$log_script" "$ui_reset_script"
    chown root:root "$action_script" "$log_script" "$ui_reset_script"

    echo "Installed helper scripts:"
    echo "  $action_script"
    echo "  $log_script"
    echo "  $ui_reset_script"
}

install_sudoers_rule() {
    local sudoers_file="${SUDOERS_DIR}/${TARGET_USER}-codesys-control"

    install -d "$SUDOERS_DIR"
    cat >"$sudoers_file" <<EOF
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action start
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action stop
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-action restart
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/codesys-control-log-tail
${TARGET_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/machine-ui-reset-build-cache
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
    echo "  sudo -n ${INSTALL_DIR}/machine-ui-reset-build-cache"
    echo "  sudo -n ${TAIL_BIN} -n ${LOG_TAIL_LINE_COUNT} ${LOG_FILE}"
}

main() {
    parse_args "$@"
    require_root
    resolve_target_user
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