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
  _require_command sudo
  _require_command curl
  _require_command jq
  if _is_gui && _has_command zenity; then
    IS_GUI=true
  fi
  _is_interactive || { IS_INTERACTIVE=false; IS_GUI=false; }
  preflight_check_sudo
  preflight_check_systemd
  preflight_check_existing_install
  preflight_actions
  preflight_print_summary
}

preflight_actions() {
  USER_HOME="$(getent passwd "${CURRENT_USER}" | cut -d: -f6)"
  HOMEBREW_FOLDER="${USER_HOME}/homebrew"
  WORKDIR="$(mktemp -d)"
}

preflight_print_summary() {
  local elevated=false
  [[ "${EUID}" -eq 0 ]] && elevated=true
  printf "User       : %s\n" "${CURRENT_USER}"
  printf "OS         : %s\n" "${OS_NAME}"
  printf "Interactive: %s\n" "${IS_INTERACTIVE}"
  printf "GUI        : %s\n" "${IS_GUI}"
  printf "Elevated   : %s\n" "${elevated}"
  printf "Temp pass  : %s\n" "${CHANGING_PASSWORD}"
  if [[ -f "${PLUGIN_LOADER_SERVICE}" ]]; then
    printf "Existing   : branch=%s version=%s\n" \
      "${DECKY_LOADER_INSTALLED_RELEASE_TYPE:-unknown}" "${DECKY_LOADER_VERSION:-unknown}"
  else
    printf "Existing   : none\n"
  fi
}

_defaults(){
  IS_GUI=false
  IS_INTERACTIVE=true
  CHANGING_PASSWORD=false
  SUDO_PASS=""
  readonly DECKY_TEMP_PASS="Decky!"
  readonly PLUGIN_LOADER_SERVICE="/etc/systemd/system/plugin_loader.service"
  readonly DECKY_LOADER_BASE_URL="https://api.github.com/repos/SteamDeckHomebrew/decky-loader"
  DECKY_LOADER_INSTALLED_RELEASE_TYPE=""
  DECKY_LOADER_VERSION=""
  DECKY_LOADER_RELEASE_TYPE="release"
  USER_HOME=""
  HOMEBREW_FOLDER=""
  WORKDIR=""
}

dispatch_action() {
  local ACTION="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$ACTION" in
    install) install "$@" ;;
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

_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif [[ -n "${SUDO_PASS:-}" ]]; then
    echo "${SUDO_PASS}" | sudo -S "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

_prompt_password() {
  local prompt="${1:-Password: }" pass
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    pass=$(zenity --password --title="Decky Installer" 2>/dev/null) \
      || _error "Password entry cancelled."
  else
    read -rsp "${prompt}" pass
    printf "\n" >&2
  fi
  printf "%s" "${pass}"
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
      NP)
        printf "WARNING: No admin password set. Temporarily setting password to '%s' for this installation.\n" "${DECKY_TEMP_PASS}" >&2
        yes "${DECKY_TEMP_PASS}" | passwd "${CURRENT_USER}"
        SUDO_PASS="${DECKY_TEMP_PASS}"
        CHANGING_PASSWORD=true
        return 0 ;;
      L|LK)
        _error "User ${CURRENT_USER} account is locked and requires a password for sudo. Cannot proceed." ;;
      *)
        [[ "${IS_INTERACTIVE}" != true ]] && \
          _error "User ${CURRENT_USER} requires a sudo password but the script is running non-interactively."
        local pass
        while true; do
          pass=$(_prompt_password "Enter sudo password for ${CURRENT_USER}: ")
          if echo "${pass}" | sudo -S -k true 2>/dev/null; then
            SUDO_PASS="${pass}"
            return 0
          fi
          printf "Incorrect password, try again.\n" >&2
        done ;;
    esac
  fi

  _error "Cannot verify sudo permissions for ${CURRENT_USER}: ${sudo_output}"
}

preflight_check_systemd() {
  _has_command systemctl || _error "systemctl not found. This installer requires systemd."
  local state
  state=$(systemctl is-system-running 2>/dev/null || true)
  case "${state}" in
    running|degraded) ;;
    *) _error "systemd is not running (state: ${state:-unknown})." ;;
  esac
}

preflight_check_existing_install() {
  [[ -f "${PLUGIN_LOADER_SERVICE}" ]] || return 0
  DECKY_LOADER_INSTALLED_RELEASE_TYPE=$(grep '^# DECKY_LOADER_RELEASE_TYPE=' "${PLUGIN_LOADER_SERVICE}" | cut -d= -f2 || true)
  DECKY_LOADER_VERSION=$(grep '^# DECKY_LOADER_VERSION=' "${PLUGIN_LOADER_SERVICE}" | cut -d= -f2 || true)
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
  if [[ "${CHANGING_PASSWORD:-false}" == true && -n "${SUDO_PASS:-}" ]]; then
    echo "${SUDO_PASS}" | sudo -S -k passwd -d "${CURRENT_USER}" 2>/dev/null || true
  fi
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
  install_archive_components
  install_install_service
  doctor
}

install_require_root(){
  [[ "${EUID}" -eq 0 ]] || _has_command sudo || \
    _error "Installation requires root or sudo access."
}
install_setup_dirs(){
  _sudo mkdir -p "${HOMEBREW_FOLDER}/services" "${HOMEBREW_FOLDER}/plugins"
  _sudo chown -R "${CURRENT_USER}":"${CURRENT_USER}" "${HOMEBREW_FOLDER}"
  _sudo chown -R 0:0 "${HOMEBREW_FOLDER}/services"
}
install_prepare_steam(){
  test -d "${USER_HOME}/.steam/steam/" && touch "${USER_HOME}/.steam/steam/.cef-enable-remote-debugging"
  test -d "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/" && touch "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
}
install_download_components(){
  local release download_url

  local is_prerelease=false
  [[ "${DECKY_LOADER_RELEASE_TYPE}" == prerelease ]] && is_prerelease=true

  printf "Fetching %s release info...\n" "${DECKY_LOADER_RELEASE_TYPE}"
  release=$(curl -sf "${DECKY_LOADER_BASE_URL}/releases" \
    | jq -r --argjson pre "${is_prerelease}" 'first(.[] | select(.prerelease == $pre))') \
    || _error "Failed to fetch release list from GitHub."
  [[ -z "${release}" || "${release}" == null ]] && \
    _error "No ${DECKY_LOADER_RELEASE_TYPE} release found."

  DECKY_LOADER_VERSION=$(jq -r '.tag_name' <<< "${release}")
  [[ -z "${DECKY_LOADER_VERSION}" || "${DECKY_LOADER_VERSION}" == null ]] && \
    _error "Could not parse version from ${DECKY_LOADER_RELEASE_TYPE} release metadata."
  printf "Found version: %s\n" "${DECKY_LOADER_VERSION}"

  download_url=$(jq -r '.assets[].browser_download_url | select(endswith("PluginLoader"))' <<< "${release}")
  [[ -z "${download_url}" ]] && \
    _error "No PluginLoader asset found in ${DECKY_LOADER_RELEASE_TYPE} release ${DECKY_LOADER_VERSION}."

  printf "Downloading PluginLoader %s...\n" "${DECKY_LOADER_VERSION}"
  curl -Lf "${download_url}" -o "${WORKDIR}/PluginLoader" \
    || _error "Failed to download PluginLoader ${DECKY_LOADER_VERSION}."

  printf "Downloading plugin_loader service file...\n"
  curl -Lf "https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service" \
    -o "${WORKDIR}/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service" \
    || _error "Failed to download plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service."

  printf "%s" "${DECKY_LOADER_VERSION}" > "${WORKDIR}/.loader.version"
  printf "Download complete.\n"
}
install_archive_components(){
  local archive_dir="${HOMEBREW_FOLDER}/archive/${DECKY_LOADER_VERSION}"
  printf "Archiving artifacts to %s...\n" "${archive_dir}"
  mkdir -p "${archive_dir}"
  cp "${WORKDIR}/PluginLoader" "${archive_dir}/PluginLoader"
  cp "${WORKDIR}/.loader.version" "${archive_dir}/.loader.version"
  {
    printf "# DECKY_LOADER_RELEASE_TYPE=%s\n" "${DECKY_LOADER_RELEASE_TYPE}"
    printf "# DECKY_LOADER_VERSION=%s\n" "${DECKY_LOADER_VERSION}"
    cat "${WORKDIR}/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service"
  } > "${archive_dir}/plugin_loader.service"
}
install_install_service(){
  local archive_dir="${HOMEBREW_FOLDER}/archive/${DECKY_LOADER_VERSION}"

  if [[ -f "${PLUGIN_LOADER_SERVICE}" ]]; then
    printf "Stopping existing service...\n"
    _sudo systemctl stop plugin_loader 2>/dev/null || true
  fi

  printf "Installing PluginLoader to services...\n"
  _sudo cp "${archive_dir}/PluginLoader" "${HOMEBREW_FOLDER}/services/PluginLoader"
  _sudo cp "${archive_dir}/.loader.version" "${HOMEBREW_FOLDER}/services/.loader.version"

  printf "Installing systemd unit...\n"
  _sudo cp "${archive_dir}/plugin_loader.service" "${PLUGIN_LOADER_SERVICE}"
  _sudo systemctl daemon-reload
  printf "Enabling and starting plugin_loader...\n"
  _sudo systemctl enable --now plugin_loader
}
doctor(){
  :
}
main "$@"

# Do not forget:
# - Flags management
# - Trap error
# - Revert changes
# - get back sudo password
# - clean WORKDIR
