#!/usr/bin/env bash
# vim: set ft=bash ts=2 sw=2 sts=2 expandtab :
# Use _msg or _error for important messages
# They show in both terminal and hui
# printf for debug messages
DECKY_LOADER_VERSION=2.0.0

set -euo pipefail
trap 'handle_err "${LINENO:-?}"' ERR
trap cleanup_exit EXIT INT TERM

main() {
  _defaults
  [[ "${1:-}" == help ]] && help
  preflight_checks
  if [[ "${IS_INTERACTIVE}" == true && $# -eq 0 ]]; then
    interactive_menu
  else
    dispatch_action "$@"
  fi
}

help(){
  _msg "Decky Installer Suite ░▒▓█\nhelp menu placeholder"
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
  greeting
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
    uninstall) [[ -d "${HOMEBREW_FOLDER}" ]] && export_decky; uninstall ;;
    rollback) rollback "$@" ;;
    cleanup) cleanup "$@" ;;
    export) export_decky ;;
    import) import_decky "$@" ;;
    help|"") help ;;
    *) _error "Unknown action: $ACTION" ;;
  esac
}

_error() {
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf "█▓▒░ ERROR: %s\n" "${line}" >&2
  done < <(printf "%b" "$*")
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    zenity --error --title="Decky Installer" --text="$(printf "%b" "$*")" --no-wrap 2>/dev/null || true
  fi
  exit 1
}

_msg() {
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf "█▓▒░ %s\n" "${line}"
  done < <(printf "%b" "$*")
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    zenity --info --title="Decky Installer" --text="$(printf "%b" "$*")" --no-wrap 2>/dev/null || true
  fi
}

greeting() {
  _msg "Decky Installer Suite ░▒▓█\nVersion ${DECKY_LOADER_VERSION}\nScript is downloaded from https://github.com/SteamDeckHomebrew/decky-installer\n\nIt is a script for installing Decky Loader"
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
    return
  fi

  if [[ -n "${SUDO_PASS:-}" ]]; then
    echo "${SUDO_PASS}" | sudo -S "$@" 2>/dev/null
    return
  fi

  if sudo -n "$@" 2>/dev/null; then
    return
  fi

  local pass
  pass=$(_prompt_password "Enter sudo password for ${CURRENT_USER}: ") \
    || _error "Password entry cancelled."
  SUDO_PASS="${pass}"
  echo "${SUDO_PASS}" | sudo -S "$@" 2>/dev/null
}

_prompt_password() {
  local prompt="${1:-Password: }" pass
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    pass=$(zenity --password --title="Decky Installer" 2>/dev/null) || return 1
  else
    read -rsp "${prompt}" pass </dev/tty || return 1
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
        _msg "Sudo password required for ${CURRENT_USER}."
        while true; do
          pass=$(_prompt_password "Enter sudo password for ${CURRENT_USER}: ") \
            || _error "Password entry cancelled."
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

_select() {
  local title="$1"; shift
  local -a options=("$@")
  if [[ "${IS_GUI}" == true ]]; then
    zenity --list --title="Decky Installer" --text="${title}" \
           --column="Action" --hide-header "${options[@]}"
  else
    printf "%s\n" "${title}" >&2
    select opt in "${options[@]}"; do
      [[ -n "${opt}" ]] && printf "%s" "${opt}" && return 0
    done
  fi
}

interactive_menu() {
  local choice
  choice=$(_select "Choose an action:" \
    "install" "uninstall" "rollback" "cleanup" "export" "import" "doctor" "help") \
    || _error "No action selected."

  if [[ "${choice}" == "install" ]]; then
    local branch
    branch=$(_select "Select release branch:" "release" "prerelease") \
      || _error "No branch selected."
    DECKY_LOADER_RELEASE_TYPE="${branch}"
  fi

  dispatch_action "${choice}"
}

cleanup_exit() {
  if [[ "${CHANGING_PASSWORD:-false}" == true && -n "${SUDO_PASS:-}" ]]; then
    echo "${SUDO_PASS}" | sudo -S -k passwd -d "${CURRENT_USER}" 2>/dev/null || true
  fi
  test -d "${WORKDIR:-/dev/null}" && find "${WORKDIR}" -delete
  if [[ "${IS_INTERACTIVE:-false}" == true ]]; then
    printf "█▓▒░ Press (A)/[Enter] to close terminal\n"
    read -r _ </dev/tty 2>/dev/null || true
  fi
}

export_decky() {
  local timestamp downloads export_path
  timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
  downloads="${USER_HOME}/Downloads"
  export_path="${downloads}/decky-export-${timestamp}.tar.gz"

  [[ -d "${downloads}" ]] || mkdir -p "${downloads}"

  printf "Exporting Decky data to %s...\n" "${export_path}"
  tar -czf "${export_path}" \
    -C "${HOMEBREW_FOLDER}" \
    --exclude="./services" \
    --exclude="./archive" \
    . \
    || _error "Failed to create export archive."
  _msg "Export complete: ${export_path}\nExport contains Decky plugins, settings, and anything else user-facing"
}

import_decky() {
  local archive_path="${1:-}"
  local strategy="${2:-}"

  if [[ -z "${archive_path}" || -z "${strategy}" ]]; then
    [[ "${IS_INTERACTIVE}" == true ]] || \
      _error "import requires an archive path and strategy in non-interactive mode."

    local source_choice
    source_choice=$(_select "Select archive source:" \
      "Enter path manually" "Find archive automatically") \
      || _error "No source selected."

    strategy=$(_select "How to treat existing data:" \
      "backup-wipe-import" "merge-overwrite") \
      || _error "No strategy selected."

    case "${source_choice}" in
      "Enter path manually")
        printf "Enter absolute path to archive: " >&2
        read -r archive_path </dev/tty || _error "Path entry cancelled."
        ;;
      "Find archive automatically")
        local -a found
        mapfile -t found < <(find "${USER_HOME}" -name "decky-export-*.tar.gz" 2>/dev/null | sort -r)
        [[ "${#found[@]}" -gt 0 ]] || _error "No decky-export-*.tar.gz archives found in ${USER_HOME}."
        archive_path=$(_select "Select archive to import:" "${found[@]}") \
          || _error "No archive selected."
        ;;
    esac
  fi

  [[ -f "${archive_path}" ]] || _error "Archive not found: ${archive_path}"

  case "${strategy}" in
    backup-wipe-import)
      if [[ -d "${HOMEBREW_FOLDER}" ]]; then
        printf "Backing up existing data before wipe...\n"
        export_decky
        printf "Wiping user-facing content in %s...\n" "${HOMEBREW_FOLDER}"
        find "${HOMEBREW_FOLDER}" -mindepth 1 -maxdepth 1 \
          ! -name "services" ! -name "archive" \
          -exec rm -rf {} +
      fi
      printf "Extracting %s into %s...\n" "${archive_path}" "${HOMEBREW_FOLDER}"
      mkdir -p "${HOMEBREW_FOLDER}"
      tar -xzf "${archive_path}" -C "${HOMEBREW_FOLDER}" \
        || _error "Failed to extract archive."
      ;;
    merge-overwrite)
      printf "Merging %s into %s...\n" "${archive_path}" "${HOMEBREW_FOLDER}"
      mkdir -p "${HOMEBREW_FOLDER}"
      tar -xzf "${archive_path}" -C "${HOMEBREW_FOLDER}" \
        || _error "Failed to extract archive."
      ;;
    *)
      _error "Unknown strategy: ${strategy}. Use 'backup-wipe-import' or 'merge-overwrite'."
      ;;
  esac

  _msg "Import complete."
}

uninstall() {
  printf "Uninstalling Decky Loader...\n"

  if systemctl is-active --quiet plugin_loader 2>/dev/null || \
     systemctl is-enabled --quiet plugin_loader 2>/dev/null; then
    printf "Stopping and disabling plugin_loader service...\n"
    _sudo systemctl stop plugin_loader 2>/dev/null || true
    _sudo systemctl disable plugin_loader 2>/dev/null || true
  fi

  if [[ -f "${PLUGIN_LOADER_SERVICE}" ]]; then
    printf "Removing systemd unit file...\n"
    _sudo rm -f "${PLUGIN_LOADER_SERVICE}"
    _sudo systemctl daemon-reload
  fi

  local cef_paths=(
    "${USER_HOME}/.steam/steam/.cef-enable-remote-debugging"
    "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
  )
  for cef in "${cef_paths[@]}"; do
    if [[ -f "${cef}" ]]; then
      printf "Removing %s...\n" "${cef}"
      rm -f "${cef}"
    fi
  done

  if [[ -d /tmp/plugin_loader ]]; then
    printf "Removing /tmp/plugin_loader...\n"
    _sudo find /tmp/plugin_loader -delete
  fi

  if [[ -d "${HOMEBREW_FOLDER}" ]]; then
    printf "Purging %s...\n" "${HOMEBREW_FOLDER}"
    _sudo find "${HOMEBREW_FOLDER}" -delete
  fi

  _msg "Decky Loader uninstalled."
}

rollback() {
  _error "Not yet implemented: rollback"
}

cleanup() {
  local keep="${1:-3}"
  local archive_dir="${HOMEBREW_FOLDER}/archive"
  [[ -d "${archive_dir}" ]] || { _msg "No archive directory found."; return 0; }

  local -a versions
  mapfile -t versions < <(find "${archive_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' \
    | sort -rn | awk '{print $2}')
  local total="${#versions[@]}"

  if [[ "${total}" -le "${keep}" ]]; then
    _msg "Nothing to cleanup (${total} archived version(s), keeping ${keep})."
    return 0
  fi

  local -a to_delete=("${versions[@]:${keep}}")
  local -a to_delete_paths=("${to_delete[@]/#/${archive_dir}/}")
  local freed
  freed=$(du -sch "${to_delete_paths[@]}" 2>/dev/null | tail -1 | awk '{print $1}')

  _msg "Removing ${#to_delete[@]} old archive(s), keeping ${keep} newest (freeing ~${freed})..."
  for version in "${to_delete[@]}"; do
    printf "  Removing %s\n" "${version}"
    _sudo rm -rf "${archive_dir:?}/${version}"
  done
}

install() {
  printf "Installing Decky Loader (%s)...\n" "${DECKY_LOADER_RELEASE_TYPE}"
  install_setup_dirs
  install_prepare_steam
  install_download_components
  install_archive_components
  install_install_service
  doctor
  _msg "Decky Loader ${DECKY_LOADER_VERSION} installed successfully."
}

install_setup_dirs(){
  printf "Setting up directories in %s...\n" "${HOMEBREW_FOLDER}"
  _sudo mkdir -p "${HOMEBREW_FOLDER}/services" "${HOMEBREW_FOLDER}/plugins"
  _sudo chown -R "${CURRENT_USER}":"${CURRENT_USER}" "${HOMEBREW_FOLDER}"
  _sudo chown -R 0:0 "${HOMEBREW_FOLDER}/services"
}
install_prepare_steam(){
  printf "Configuring Steam for remote debugging...\n"
  if [[ -d "${USER_HOME}/.steam/steam/" ]]; then
    touch "${USER_HOME}/.steam/steam/.cef-enable-remote-debugging"
  fi
  if [[ -d "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/" ]]; then
    touch "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
  fi
  _msg "Steam remote debugging is enabled"
}
install_download_components(){
  # Add check if version is already downloaded
  local release download_url

  local is_prerelease=false
  [[ "${DECKY_LOADER_RELEASE_TYPE}" == prerelease ]] && is_prerelease=true

  printf "Fetching %s release info...\n" "${DECKY_LOADER_RELEASE_TYPE}"
  local raw
  raw=$(curl -sSf "${DECKY_LOADER_BASE_URL}/releases") \
    || _error "Failed to fetch release list from GitHub."
  if jq -e '.message' <<< "${raw}" >/dev/null 2>&1; then
    _error "GitHub API error: $(jq -r '.message' <<< "${raw}")"
  fi
  release=$(jq -r --argjson pre "${is_prerelease}" 'first(.[] | select(.prerelease == $pre))' <<< "${raw}")
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
  _msg "Download complete."
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
  _msg "Service plugin_loader enabled and started."
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
# - cleanup WORKDIR
