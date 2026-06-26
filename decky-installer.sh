#!/usr/bin/env bash
# vim: set ft=bash ts=2 sw=2 sts=2 expandtab :
# interactive menu:
# 1. install
# 1.1 select branch
# 2. uninstall
# 3. doctor
# 4. Rollback to previous version
# 5. Force clean
# 6. export_decky
VERSION=1.0.0

set -euo pipefail
trap 'handle_err "${LINENO:-?}"' ERR
trap cleanup EXIT INT TERM

main() {
  _defaults
  [[ "${1:-}" == help ]] && help
  preflight_checks
  [[ "${IS_INTERACTIVE}" == true ]] && interactive_menu
  dispatch_action "$@"
}

help(){
  printf "█▓▒░ Decky Installer Suite\n"
  exit 0
}

preflight_checks(){
  . /etc/os-release
  OS_NAME="${NAME:-unknown}"
  CURRENT_USER=$(id -un)
  _require_command jq
  if _is_gui && _has_command zenity; then
    IS_GUI=true
  fi
  _is_interactive || { IS_INTERACTIVE=false; IS_GUI=false; }
  preflight_check_sudo
  # github is available
  # mktemp
  # check if systemd is active
  # check if deckyloader is already installed and it's version
  WORKDIR="$(mktemp -d)"
  printf "User %s on %s started decky installer script\n" "${CURRENT_USER}" "${OS_NAME}"
  printf "Interactive: %s\nGUI Installer: %s\n" "${IS_INTERACTIVE}" "${IS_GUI}"
}

_defaults(){
  IS_GUI=false
  IS_INTERACTIVE=true
  CHANGING_PASSWORD=false
}

dispatch_action() {
  local ACTION="${1:-}"
  shift

  case "$ACTION" in
    install) install "$@" && cleanup;;
    uninstall) export_decky && uninstall ;;
    rollback) rollback "$@" ;;
    clean) cleanup ;;
    export) export_decky ;;
    help|"") help ;;
    *) _error "Unknown action: $ACTION" ;;
  esac
}

_error() {
  echo "ERROR: $*" >&2
  exit 1
}
_is_gui() {
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        return 0
    else
        return 1
    fi
}

_is_interactive() {
    if [[ -t 0 ]]; then
        return 0
    else
        return 1
    fi
}

_is_ssh() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

_has_command() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

handle_err() {
  local line="$1"
  echo "Unexpected error on line $line" >&2
  exit 1
}

_require_command() {
    _has_command "$1" || _error "Required command not found in PATH: $1"
}

preflight_check_sudo() {
  # Case 1: already root but no invoking user — cannot determine who to install for
  if [[ "${EUID}" -eq 0 ]]; then
    if [[ -z "${SUDO_USER:-}" ]]; then
      _error "Running as root without an invoking user. Use 'sudo' instead of logging in as root."
    fi
    # Case 2: elevated via sudo — resolve the real user and proceed
    CURRENT_USER="${SUDO_USER}"
    return 0
  fi

  # Case 3: not root — verify sudo access without prompting
  local sudo_output sudo_rc
  sudo_output=$(sudo -n -l 2>&1) && sudo_rc=0 || sudo_rc=$?

  if [[ "${sudo_rc}" -eq 0 ]]; then
    return 0
  fi

  # 3.1 Check if user is not in sudoers at all
  if echo "${sudo_output}" | grep -qE "not allowed|not in the sudoers"; then
    _error "User ${CURRENT_USER} is not in the sudoers list."
  fi

  # 3.2 User is in sudoers but a password is required — check they actually have one
  if echo "${sudo_output}" | grep -q "a password is required"; then
    local passwd_status
    passwd_status=$(passwd -S "${CURRENT_USER}" 2>/dev/null | awk '{print $2}' || true)
    case "${passwd_status}" in
      NP|L|LK)
        _error "User ${CURRENT_USER} is in sudoers but has no usable password set." ;;
      *)
        # Password present (or status undetermined — proceed and let sudo prompt)
        return 0 ;;
    esac
  fi

  _error "Cannot verify sudo permissions for ${CURRENT_USER}: ${sudo_output}"
}

interactive_menu(){
  :
}
select_action(){
  :
  # install release
  # install prerelease
  # uninstall
  # doctor
}

cleanup() {
  test -d "${WORKDIR:-/dev/null}" && find "${WORKDIR}" -delete
}

export_decky() {
  _error "Not yet implemented: export"
}

uninstall() {
  _error "Not yet implemented: uninstall"
}

rollback() {
  _error "Not yet implemented: rollback"
}

install() {
  install_require_root
  install_setup_dirs
  install_prepare_steam
  install_download_components
  install_install_service
  install_enable_service
}

install_require_root(){
  :
}
install_setup_dirs(){
  mkdir -p ~/homebrew/services/ ~/homebrew/plugins/
  chown -R "${CURRENT_USER}":"${CURRENT_USER}" ~/homebrew/
  chown -R 0:0 ~/homebrew/services/
}
install_prepare_steam(){
  test -d "${HOME}/.steam/steam/" && touch "${HOME}/.steam/steam/.cef-enable-remote-debugging"
  test -d "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/" && touch "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
}
install_download_components(){
  :
}
install_install_service(){
  :
}
install_enable_service(){
  :
}
main "$@"

# Do not forget:
# - Flags management
# - Trap error
# - Revert changes
# - get back sudo password
# - clean WORKDIR
