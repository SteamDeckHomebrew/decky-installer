#!/usr/bin/env bash
# vim: set ft=bash ts=2 sw=2 sts=2 expandtab :
# Use _msg or _error for important messages
# They show in both terminal and hui
# printf for debug messages
readonly SCRIPT_VERSION=2.1.0

set -euo pipefail
trap 'handle_err "${LINENO:-?}" "$?" "${BASH_COMMAND}"' ERR
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

help() {
  _msg 'Decky Installer Suite ░▒▓█
Usage: decky-installer.sh [action] [args]

Actions:
  install [version]               Install Decky Loader (latest or specific version, e.g. v3.2.6)
  uninstall                       Remove Decky Loader and all data
  rollback [version]              Roll back to an archived version
  cleanup [keep]                  Delete old archived versions (default: keep 3)
  export                          Export plugins/settings to ~/Downloads/decky-export-*.tar.gz
  import <archive> <strategy>     Restore from export; strategy: backup-wipe-import | merge-overwrite
  doctor                          Run health checks on an existing installation
  help                            Show this message

Environment:
  DECKY_LOADER_RELEASE_TYPE=prerelease   Install prerelease instead of stable
  GITHUB_TOKEN=<token>                   Authenticate GitHub API calls (avoids 60 req/hr limit)
  HOMEBREW_FOLDER=<path>                 Override install location (default: ~/homebrew)
  DECKY_CLEANUP_KEEP=<n>                 Default number of archived versions to keep (default: 3)
  NO_COLOR=1                             Disable colored output'
  exit 0
}

preflight_checks() {
  # shellcheck source=/dev/null
  OS_NAME=$(. /etc/os-release 2>/dev/null; printf '%s' "${NAME:-unknown}")
  CURRENT_USER=$(id -un)
  # Resolve the real invoking user if already running as root (e.g. via sudo)
  if [[ "${EUID}" -eq 0 ]]; then
    [[ -n "${SUDO_USER:-}" ]] \
      || _error "Running as root without an invoking user. Use 'sudo' instead of logging in as root."
    CURRENT_USER="${SUDO_USER}"
  fi
  _require_command sudo
  _require_command curl
  _require_command jq
  if _is_gui && _has_command zenity; then
    IS_GUI=true
  fi
  _is_interactive || { IS_INTERACTIVE=false; IS_GUI=false; }
  preflight_check_systemd
  preflight_check_existing_install
  preflight_init_paths
  greeting
  preflight_print_summary
}

preflight_init_paths() {
  USER_HOME="$(getent passwd "${CURRENT_USER}" | cut -d: -f6)"
  HOMEBREW_FOLDER="${HOMEBREW_FOLDER:-${USER_HOME}/homebrew}"
  WORKDIR="$(mktemp -d)"
  _init_cef_paths
}

preflight_print_summary() {
  local elevated=false
  [[ "${EUID}" -eq 0 ]] && elevated=true
  _msg "User       : ${CURRENT_USER}
OS         : ${OS_NAME}
Interactive: ${IS_INTERACTIVE}
GUI        : ${IS_GUI}
Elevated   : ${elevated}
Temp pass  : ${CHANGING_PASSWORD}
Current DeckyLoader version: ${DECKY_LOADER_VERSION:-none}
Current DeckyLoader branch : ${DECKY_LOADER_INSTALLED_RELEASE_TYPE:-none}"
}

_defaults() {
  IS_GUI=false
  IS_INTERACTIVE=true
  CHANGING_PASSWORD=false
  SUDO_PASS=""
  _GUI_FD=""
  OS_NAME=""
  CURRENT_USER=""
  readonly DECKY_TEMP_PASS="Decky!"
  readonly PLUGIN_LOADER_SERVICE="/etc/systemd/system/plugin_loader.service"
  readonly DECKY_LOADER_BASE_URL="https://api.github.com/repos/SteamDeckHomebrew/decky-loader"
  DECKY_LOADER_INSTALLED_RELEASE_TYPE=""
  DECKY_LOADER_VERSION=""
  DECKY_LOADER_RELEASE_TYPE="release"
  DECKY_LOADER_TARGET_VERSION=""
  USER_HOME=""
  HOMEBREW_FOLDER=""
  WORKDIR=""
  CEF_PATHS=()
  DECKY_CLEANUP_KEEP="${DECKY_CLEANUP_KEEP:-3}"
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    CLR_RED='\033[0;31m'
    CLR_GREEN='\033[0;32m'
    CLR_YELLOW='\033[1;33m'
    CLR_BLUE='\033[0;34m'
    CLR_CYAN='\033[0;36m'
    CLR_NC='\033[0m'
  else
    CLR_RED='' CLR_GREEN='' CLR_YELLOW='' CLR_BLUE='' CLR_CYAN='' CLR_NC=''
  fi
}

_init_cef_paths() {
  CEF_PATHS=(
    "${USER_HOME}/.steam/steam/.cef-enable-remote-debugging"
    "${USER_HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"
  )
}

dispatch_action() {
  local ACTION="${1:-}"
  [[ $# -gt 0 ]] && shift

  [[ "${ACTION}" == "help" || -z "${ACTION}" ]] || _gui_open

  # Only verify/obtain sudo credentials for actions that actually need root
  case "$ACTION" in
    install|uninstall|rollback|cleanup) preflight_check_sudo ;;
  esac

  case "$ACTION" in
    install) install "$@" ;;
    uninstall) uninstall "$@" ;;
    rollback) rollback "$@" ;;
    cleanup) cleanup "$@" ;;
    export) export_decky "$@" ;;
    import) import_decky "$@" ;;
    doctor) doctor "$@" ;;
    help|"") help ;;
    *) _error "Unknown action: $ACTION" ;;
  esac
}

_gui_open() {
  [[ "${IS_GUI:-false}" == true ]] || return 0
  _has_command zenity || return 0
  # shellcheck disable=SC2094
  exec {_GUI_FD}> >(zenity --progress --pulsate --no-cancel \
    --title="Decky Installer" --text="Starting..." 2>/dev/null) || true
}

_gui_close() {
  [[ -n "${_GUI_FD:-}" ]] || return 0
  printf "100\n" 1>&"${_GUI_FD}" 2>/dev/null || true
  exec {_GUI_FD}>&- 2>/dev/null || true
  _GUI_FD=""
}

_gui_update() {
  [[ -n "${_GUI_FD:-}" ]] || return 0
  printf "#%s\n" "$(printf "%b" "$*")" 1>&"${_GUI_FD}" 2>/dev/null || true
}

_error() {
  local text="${*//\\n/$'\n'}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf "%b█▓▒░ ERROR:%b %s\n" "${CLR_RED}" "${CLR_NC}" "${line}" >&2
  done <<< "${text}"
  _gui_close
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    zenity --error --title="Decky Installer" --text="${text}" --no-wrap 2>/dev/null || true
  fi
  exit 1
}

_msg() {
  local text="${*//\\n/$'\n'}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf "%b█▓▒░%b %s\n" "${CLR_CYAN}" "${CLR_NC}" "${line}"
  done <<< "${text}"
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    _gui_update "${text}"
  fi
}

greeting() {
  _msg "Decky Installer Suite ░▒▓█\nVersion ${SCRIPT_VERSION}\nScript is downloaded from https://github.com/SteamDeckHomebrew/decky-installer\n\nIt is a script for installing Decky Loader"
}

_is_gui() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

_is_interactive() {
  [[ -t 0 ]]
}


_has_command() {
  command -v "$1" >/dev/null 2>&1
}

# Wrapper for GitHub API calls — passes auth token when GITHUB_TOKEN is set,
# avoiding the 60 req/hr anonymous rate limit.
_github_curl() {
  local -a auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${auth[@]}" "$@"
}

_github_api() {
  local url="$1" context="${2:-GitHub API}"
  local raw
  raw=$(_github_curl -sSf "${url}") || _error "Failed to fetch ${context} from GitHub."
  if jq -e '.message' <<< "${raw}" >/dev/null 2>&1; then
    _error "GitHub API error: $(jq -r '.message' <<< "${raw}")"
  fi
  printf '%s' "${raw}"
}

handle_err() {
  local line="$1" rc="$2" cmd="$3"
  _error "Unexpected error on line ${line} (exit ${rc}): ${cmd}"
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
    printf '%s\n' "${SUDO_PASS}" | sudo -S "$@"
    return
  fi

  # Quiet probe — only checking capability, not running the real command
  if sudo -n true 2>/dev/null; then
    sudo "$@"
    return
  fi

  local pass
  pass=$(_prompt_password "Enter sudo password for ${CURRENT_USER}: ") \
    || _error "Password entry cancelled."
  SUDO_PASS="${pass}"
  printf '%s\n' "${SUDO_PASS}" | sudo -S "$@"
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

_prompt_text() {
  local prompt="${1:-Input: }" text
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    text=$(zenity --entry --title="Decky Installer" --text="${prompt}" 2>/dev/null) || return 1
  else
    printf "%s" "${prompt}" >&2
    read -r text </dev/tty || return 1
  fi
  printf "%s" "${text}"
}

preflight_check_sudo() {
  # Already root (resolved in preflight_checks) — nothing to do here
  [[ "${EUID}" -eq 0 ]] && return 0

  # Not root — verify sudo access without prompting
  local sudo_output sudo_rc
  sudo_output=$(sudo -n -l 2>&1) && sudo_rc=0 || sudo_rc=$?

  if [[ "${sudo_rc}" -eq 0 ]]; then
    return 0
  fi

  # Check if user is not in sudoers at all
  if grep -qE "not allowed|not in the sudoers" <<<"${sudo_output}"; then
    _error "User ${CURRENT_USER} is not in the sudoers list."
  fi

  # User is in sudoers but a password is required — check they actually have one
  if grep -q "a password is required" <<<"${sudo_output}"; then
    local passwd_status
    passwd_status=$(passwd -S "${CURRENT_USER}" 2>/dev/null | awk '{print $2}' || true)
    case "${passwd_status}" in
      NP)
        _msg "WARNING: No sudo password set for ${CURRENT_USER}.
WARNING: Temporarily setting account password to '${DECKY_TEMP_PASS}' for this session.
WARNING: It will be cleared on exit. Do NOT interrupt the script with SIGKILL."
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
          if sudo -S -k true <<<"${pass}" 2>/dev/null; then
            SUDO_PASS="${pass}"
            return 0
          fi
          _msg "Incorrect password, try again."
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
  DECKY_LOADER_INSTALLED_RELEASE_TYPE=$(grep '^# DECKY_LOADER_RELEASE_TYPE=' "${PLUGIN_LOADER_SERVICE}" | cut -d= -f2- || true)
  DECKY_LOADER_VERSION=$(grep '^# DECKY_LOADER_VERSION=' "${PLUGIN_LOADER_SERVICE}" | cut -d= -f2- || true)
}

_confirm() {
  local prompt="${1:-Are you sure?}"
  [[ "${IS_INTERACTIVE}" != true ]] && return 0
  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    zenity --question --title="Decky Installer" --text="${prompt}" 2>/dev/null
  else
    local answer
    printf "%s [y/N] " "${prompt}" >&2
    read -r answer </dev/tty || return 1
    [[ "${answer}" =~ ^[Yy]$ ]]
  fi
}

_select() {
  local title="$1"; shift
  local -a options=("$@")
  if [[ "${IS_GUI}" == true ]]; then
    zenity --list --title="Decky Installer" --text="${title}" \
           --column="Action" --hide-header "${options[@]}" 2>/dev/null
  else
    printf "%s\n" "${title}" >&2
    select opt in "${options[@]}"; do
      [[ -n "${opt}" ]] && printf "%s" "${opt}" && return 0
    done
    return 1  # EOF / Ctrl-D without a valid selection
  fi
}

interactive_menu() {
  local choice
  choice=$(_select "Choose an action:" \
    "install" "uninstall" "rollback" "cleanup" "export" "import" "doctor" "help") \
    || _error "No action selected."

  if [[ "${choice}" == "install" ]]; then
    local branch version_input
    branch=$(_select "Select release branch:" "release" "prerelease") \
      || _error "No branch selected."
    DECKY_LOADER_RELEASE_TYPE="${branch}"
    version_input=$(_prompt_text "Enter specific version to install (leave blank for latest):") || true
    if [[ -n "${version_input}" ]]; then
      _validate_version "${version_input}"
      DECKY_LOADER_TARGET_VERSION="${version_input}"
    fi
  fi

  dispatch_action "${choice}"
}

cleanup_exit() {
  if [[ "${CHANGING_PASSWORD:-false}" == true && -n "${SUDO_PASS:-}" ]]; then
    printf '%s\n' "${SUDO_PASS}" | sudo -S -k passwd -d "${CURRENT_USER}" 2>/dev/null || true
  fi
  [[ -d "${WORKDIR}" ]] && find "${WORKDIR}" -delete
  _gui_close
  if [[ "${IS_INTERACTIVE:-false}" == true ]]; then
    printf "█▓▒░ Press (A)/[Enter] to close terminal\n"
    read -r _ </dev/tty 2>/dev/null || true
  fi
}

export_decky() {
  if [[ "${1:-}" == help ]]; then
    _msg 'Usage: export
  Archives Decky plugins and settings to ~/Downloads/decky-export-<timestamp>.tar.gz
  Services and archived versions are excluded from the export.'
    return 0
  fi
  [[ $# -gt 0 ]] && _error "export takes no arguments. Did you mean 'import'?"
  local timestamp downloads export_path
  timestamp=$(date '+%Y%m%dT%H%M%S%z')
  downloads="${USER_HOME}/Downloads"
  export_path="${downloads}/decky-export-${timestamp}.tar.gz"

  [[ -d "${downloads}" ]] || mkdir -p "${downloads}"

  _msg "Exporting Decky data to ${export_path}..."
  tar -czf "${export_path}" \
    -C "${HOMEBREW_FOLDER}" \
    --exclude="./services" \
    --exclude="./archive" \
    . \
    || _error "Failed to create export archive."
  _msg "Export complete: ${export_path}\nExport contains Decky plugins, settings, and anything else user-facing"
}

_import_prompt_args() {
  local -n _ref_archive="$1" _ref_strategy="$2"

  local source_choice
  source_choice=$(_select "Select archive source:" \
    "Enter path manually" "Find archive automatically") \
    || _error "No source selected."

  _ref_strategy=$(_select "How to treat existing data:" \
    "backup-wipe-import" "merge-overwrite") \
    || _error "No strategy selected."

  case "${source_choice}" in
    "Enter path manually")
      _ref_archive=$(_prompt_text "Enter absolute path to archive:") \
        || _error "Path entry cancelled."
      ;;
    "Find archive automatically")
      local -a found
      mapfile -t found < <(find "${USER_HOME}" -name "decky-export-*.tar.gz" 2>/dev/null | sort -r)
      [[ "${#found[@]}" -gt 0 ]] || _error "No decky-export-*.tar.gz archives found in ${USER_HOME}."
      _ref_archive=$(_select "Select archive to import:" "${found[@]}") \
        || _error "No archive selected."
      ;;
  esac
}

import_decky() {
  local archive_path="${1:-}"
  local strategy="${2:-}"

  if [[ "${archive_path}" == help ]]; then
    _msg 'Usage: import <archive> <strategy>
  archive   Path to a decky-export-*.tar.gz file
  strategy  How to handle existing data:
              backup-wipe-import  Export current data, wipe, then import
              merge-overwrite     Extract archive on top of existing data'
    return 0
  fi
  [[ $# -gt 2 ]] && _error "import takes at most two arguments (archive, strategy); unexpected: ${*:3}"

  if [[ -z "${archive_path}" || -z "${strategy}" ]]; then
    if [[ "${IS_INTERACTIVE}" != true ]]; then
      _msg 'Usage: import <archive> <strategy>
  archive   Path to a decky-export-*.tar.gz file
  strategy  backup-wipe-import | merge-overwrite'
      _error "import requires an archive path and strategy in non-interactive mode."
    fi
    _import_prompt_args archive_path strategy
  fi

  [[ -f "${archive_path}" ]] || _error "Archive not found: ${archive_path}"

  case "${strategy}" in
    backup-wipe-import)
      if [[ -d "${HOMEBREW_FOLDER}" ]]; then
        _confirm "This will wipe user-facing content in ${HOMEBREW_FOLDER} before import. Continue?" \
          || { _msg "Import cancelled."; return 0; }
        _msg "Backing up existing data before wipe..."
        export_decky
        _msg "Wiping user-facing content in ${HOMEBREW_FOLDER}..."
        find "${HOMEBREW_FOLDER}" -mindepth 1 -maxdepth 1 \
          ! -name "services" ! -name "archive" \
          -exec rm -rf -- {} +
      fi
      _msg "Extracting ${archive_path} into ${HOMEBREW_FOLDER}..."
      mkdir -p "${HOMEBREW_FOLDER}"
      tar -xzf "${archive_path}" -C "${HOMEBREW_FOLDER}" \
        || _error "Failed to extract archive."
      ;;
    merge-overwrite)
      _msg "Merging ${archive_path} into ${HOMEBREW_FOLDER}..."
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
  if [[ "${1:-}" == help ]]; then
    _msg 'Usage: uninstall
  Stops and removes Decky Loader, its systemd service, and all data in ~/homebrew/
  A backup export is created in ~/Downloads/ before removal.'
    return 0
  fi
  [[ $# -gt 0 ]] && _error "uninstall takes no arguments."
  _confirm "This will permanently remove Decky Loader and all data in ${HOMEBREW_FOLDER}. Continue?" \
    || { _msg "Uninstall cancelled."; return 0; }
  if [[ -d "${HOMEBREW_FOLDER}" ]]; then
    _msg "Backing up Decky data before removal..."
    export_decky
  fi
  _msg "Uninstalling Decky Loader..."

  if systemctl is-active --quiet plugin_loader 2>/dev/null || \
     systemctl is-enabled --quiet plugin_loader 2>/dev/null; then
    _msg "Stopping and disabling plugin_loader service..."
    _sudo systemctl stop plugin_loader 2>/dev/null || true
    _sudo systemctl disable plugin_loader 2>/dev/null || true
  fi

  if [[ -f "${PLUGIN_LOADER_SERVICE}" ]]; then
    _msg "Removing systemd unit file..."
    _sudo rm -f -- "${PLUGIN_LOADER_SERVICE}"
    _sudo systemctl daemon-reload
  fi

  for cef in "${CEF_PATHS[@]}"; do
    if [[ -f "${cef}" ]]; then
      _msg "Removing ${cef}..."
      rm -f "${cef}"
    fi
  done

  if [[ -d /tmp/plugin_loader ]]; then
    _msg "Removing /tmp/plugin_loader..."
    _sudo find /tmp/plugin_loader -delete
  fi

  if [[ -d "${HOMEBREW_FOLDER}" ]]; then
    _msg "Purging ${HOMEBREW_FOLDER}..."
    _sudo find "${HOMEBREW_FOLDER}" -delete
  fi

  _msg "Decky Loader uninstalled."
}

_rollback_prompt_version() {
  local -n _ref_version="$1"
  local -a versions=("${@:2}")

  if [[ "${IS_INTERACTIVE}" != true ]]; then
    _msg 'Usage: rollback <version>
  version  Version tag to roll back to (e.g. v3.2.6)
           Must already be present in ~/homebrew/archive/'
    _error "rollback requires a version argument in non-interactive mode."
  fi
  _ref_version=$(_select "Select version to roll back to:" "${versions[@]}") \
    || _error "No version selected."
}

rollback() {
  local version="${1:-}"

  if [[ "${version}" == help ]]; then
    _msg 'Usage: rollback <version>
  version  Version tag to roll back to (e.g. v3.2.6)
           Must already be present in ~/homebrew/archive/'
    return 0
  fi
  [[ $# -gt 1 ]] && _error "rollback takes at most one argument (version); unexpected: ${*:2}"

  local archive_dir="${HOMEBREW_FOLDER}/archive"
  [[ -d "${archive_dir}" ]] || _error "No archive directory found at ${archive_dir}."

  local -a versions
  mapfile -t versions < <(find "${archive_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -rV)
  [[ "${#versions[@]}" -gt 0 ]] || _error "No archived versions found in ${archive_dir}."

  if [[ -z "${version}" ]]; then
    _rollback_prompt_version version "${versions[@]}"
  else
    _validate_version "${version}"
  fi

  local target_dir="${archive_dir}/${version}"
  [[ -d "${target_dir}" ]] || _error "Version ${version} not found in archive.\nAvailable: ${versions[*]}"

  DECKY_LOADER_VERSION="${version}"
  DECKY_LOADER_RELEASE_TYPE=$(grep '^# DECKY_LOADER_RELEASE_TYPE=' "${target_dir}/plugin_loader.service" \
    | cut -d= -f2- || true)
  [[ -n "${DECKY_LOADER_RELEASE_TYPE}" ]] || DECKY_LOADER_RELEASE_TYPE="release"

  _msg "Rolling back to ${version} (${DECKY_LOADER_RELEASE_TYPE})..."
  install_service
  _msg "Rollback to ${version} complete."
}

cleanup() {
  if [[ "${1:-}" == help ]]; then
    _msg 'Usage: cleanup [keep]
  keep  Number of most-recent archived versions to retain (default: $DECKY_CLEANUP_KEEP or 3)'
    return 0
  fi
  [[ $# -gt 1 ]] && _error "cleanup takes at most one argument (keep); unexpected: ${*:2}"
  local keep="${1:-${DECKY_CLEANUP_KEEP}}"
  [[ "${keep}" =~ ^[0-9]+$ ]] || _error "cleanup: keep must be a non-negative integer; got: ${keep}"
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
    _msg "  Removing ${version}"
    _sudo find "${archive_dir:?}/${version}" -delete
  done
}

_validate_version() {
  local version="$1"
  [[ "${version}" =~ ^v?[0-9][0-9A-Za-z.+-]*$ ]] \
    || _error "Invalid version format: '${version}'. Expected e.g. v3.2.6"
}

install() {
  if [[ "${1:-}" == help ]]; then
    _msg 'Usage: install [version]
  version  Specific version to install (e.g. v3.2.6); omit for latest stable
           Set DECKY_LOADER_RELEASE_TYPE=prerelease to target prerelease channel'
    return 0
  fi
  [[ $# -gt 1 ]] && _error "install takes at most one argument (version); unexpected: ${*:2}"
  [[ -n "${1:-}" ]] && DECKY_LOADER_TARGET_VERSION="$1"
  [[ -n "${DECKY_LOADER_TARGET_VERSION}" ]] && _validate_version "${DECKY_LOADER_TARGET_VERSION}"
  _msg "Installing Decky Loader (${DECKY_LOADER_TARGET_VERSION:-${DECKY_LOADER_RELEASE_TYPE}})..."
  install_setup_dirs
  install_prepare_steam
  install_download_components
  install_archive_components
  install_service
  _msg "Decky Loader ${DECKY_LOADER_VERSION} installed successfully."
}

install_setup_dirs() {
  _msg "Setting up directories in ${HOMEBREW_FOLDER}..."
  _sudo mkdir -p "${HOMEBREW_FOLDER}/services" "${HOMEBREW_FOLDER}/plugins"
  _sudo chown -R "${CURRENT_USER}:" "${HOMEBREW_FOLDER}"
  _sudo chown -R 0:0 "${HOMEBREW_FOLDER}/services"
}

install_prepare_steam() {
  _msg "Configuring Steam for remote debugging..."
  for cef in "${CEF_PATHS[@]}"; do
    [[ -d "$(dirname "${cef}")" ]] && touch "${cef}"
  done
  _msg "Steam remote debugging is enabled"
}

_fetch_release_by_version() {
  local -n _ref_release="$1"
  local version="$2"
  _msg "Fetching release info for ${version}..."
  _ref_release=$(_github_api "${DECKY_LOADER_BASE_URL}/releases/tags/${version}" "release ${version}")
  DECKY_LOADER_RELEASE_TYPE=$(jq -r 'if .prerelease then "prerelease" else "release" end' <<< "${_ref_release}")
}

_fetch_latest_release() {
  local -n _ref_release="$1"
  local is_prerelease=false
  [[ "${DECKY_LOADER_RELEASE_TYPE}" == prerelease ]] && is_prerelease=true
  _msg "Fetching ${DECKY_LOADER_RELEASE_TYPE} release info..."
  local raw
  raw=$(_github_api "${DECKY_LOADER_BASE_URL}/releases" "release list")
  _ref_release=$(jq -r --argjson pre "${is_prerelease}" 'first(.[] | select(.prerelease == $pre))' <<< "${raw}")
  [[ -z "${_ref_release}" || "${_ref_release}" == null ]] && \
    _error "No ${DECKY_LOADER_RELEASE_TYPE} release found."
}

install_download_components() {
  local release

  if [[ -n "${DECKY_LOADER_TARGET_VERSION}" ]]; then
    _fetch_release_by_version release "${DECKY_LOADER_TARGET_VERSION}"
  else
    _fetch_latest_release release
  fi

  DECKY_LOADER_VERSION=$(jq -r '.tag_name' <<< "${release}")
  [[ -z "${DECKY_LOADER_VERSION}" || "${DECKY_LOADER_VERSION}" == null ]] && \
    _error "Could not parse version from ${DECKY_LOADER_RELEASE_TYPE} release metadata."
  _msg "Found version: ${DECKY_LOADER_VERSION}"

  if [[ -f "${HOMEBREW_FOLDER}/archive/${DECKY_LOADER_VERSION}/PluginLoader" ]]; then
    _msg "Version ${DECKY_LOADER_VERSION} already in archive, skipping download."
    return 0
  fi

  local download_url
  download_url=$(jq -r '.assets[].browser_download_url | select(endswith("PluginLoader"))' <<< "${release}")
  [[ -z "${download_url}" ]] && \
    _error "No PluginLoader asset found in ${DECKY_LOADER_RELEASE_TYPE} release ${DECKY_LOADER_VERSION}."

  _msg "Downloading PluginLoader ${DECKY_LOADER_VERSION}..."
  curl -Lf "${download_url}" -o "${WORKDIR}/PluginLoader" \
    || _error "Failed to download PluginLoader ${DECKY_LOADER_VERSION}."

  _msg "Downloading plugin_loader service file..."
  curl -Lf "https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service" \
    -o "${WORKDIR}/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service" \
    || _error "Failed to download plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service."

  printf "%s" "${DECKY_LOADER_VERSION}" > "${WORKDIR}/.loader.version"
  _msg "Download complete."
}

install_archive_components() {
  local archive_dir="${HOMEBREW_FOLDER}/archive/${DECKY_LOADER_VERSION}"
  [[ -f "${archive_dir}/PluginLoader" ]] && return 0
  _msg "Archiving artifacts to ${archive_dir}..."
  mkdir -p "${archive_dir}"
  cp "${WORKDIR}/PluginLoader" "${archive_dir}/PluginLoader"
  chmod +x "${archive_dir}/PluginLoader"
  cp "${WORKDIR}/.loader.version" "${archive_dir}/.loader.version"
  {
    printf "# DECKY_LOADER_RELEASE_TYPE=%s\n" "${DECKY_LOADER_RELEASE_TYPE}"
    printf "# DECKY_LOADER_VERSION=%s\n" "${DECKY_LOADER_VERSION}"
    cat "${WORKDIR}/plugin_loader-${DECKY_LOADER_RELEASE_TYPE}.service"
  } > "${archive_dir}/plugin_loader.service"
}

install_service() {
  local archive_dir="${HOMEBREW_FOLDER}/archive/${DECKY_LOADER_VERSION}"

  if [[ -f "${PLUGIN_LOADER_SERVICE}" ]]; then
    _msg "Stopping existing service..."
    _sudo systemctl stop plugin_loader 2>/dev/null || true
  fi

  _msg "Installing PluginLoader to services..."
  _sudo cp "${archive_dir}/PluginLoader" "${HOMEBREW_FOLDER}/services/PluginLoader"
  _sudo chmod +x "${HOMEBREW_FOLDER}/services/PluginLoader"
  _sudo cp "${archive_dir}/.loader.version" "${HOMEBREW_FOLDER}/services/.loader.version"

  _msg "Installing systemd unit..."
  local tmp_unit="${WORKDIR}/plugin_loader.service"
  sed "s|\${HOMEBREW_FOLDER}|${HOMEBREW_FOLDER}|g" "${archive_dir}/plugin_loader.service" > "${tmp_unit}"
  _sudo cp "${tmp_unit}" "${PLUGIN_LOADER_SERVICE}"
  _sudo systemctl daemon-reload
  _msg "Enabling and starting plugin_loader..."
  _sudo systemctl enable --now plugin_loader
  _msg "Service plugin_loader enabled and started."
}

_DOCTOR_OUTPUT=""

_doctor_pass() {
  printf "%b[PASS]%b %s\n" "${CLR_GREEN}" "${CLR_NC}" "$*"
  _DOCTOR_OUTPUT+="[PASS] $*\n"
  _gui_update "[PASS] $*"
}

_doctor_fail() {
  printf "%b[FAIL]%b %s\n" "${CLR_RED}" "${CLR_NC}" "$*"
  _DOCTOR_OUTPUT+="[FAIL] $*\n"
  _gui_update "[FAIL] $*"
}

_doctor_warn() {
  printf "%b[WARN]%b %s\n" "${CLR_YELLOW}" "${CLR_NC}" "$*"
  _DOCTOR_OUTPUT+="[WARN] $*\n"
  _gui_update "[WARN] $*"
}

_doctor_info() {
  printf "%b[INFO]%b %s\n" "${CLR_CYAN}" "${CLR_NC}" "$*"
  _DOCTOR_OUTPUT+="[INFO] $*\n"
  _gui_update "[INFO] $*"
}

_doctor_check() {
  local success_msg="$1" fail_msg="$2"
  shift 2
  if "$@" 2>/dev/null; then
    _doctor_pass "${success_msg}"
  else
    _doctor_fail "${fail_msg}"
  fi
}

_doctor_check_version() {
  if [[ -n "${DECKY_LOADER_VERSION}" ]]; then
    _doctor_pass "Installed version: ${DECKY_LOADER_VERSION} (${DECKY_LOADER_INSTALLED_RELEASE_TYPE:-unknown})"
  else
    _doctor_fail "No installed version detected"
  fi
}

_doctor_check_cef() {
  local found=false
  for cef in "${CEF_PATHS[@]}"; do
    [[ -f "${cef}" ]] && found=true && break
  done
  if [[ "${found}" == true ]]; then
    _doctor_pass "CEF remote debugging enabled"
  else
    _doctor_warn "CEF remote debugging file not found"
  fi
}

_doctor_check_port() {
  local port="$1" name="$2"
  if ! _has_command ss; then
    _doctor_warn "ss not available, skipping port ${port} check"
    return
  fi
  if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q .; then
    _doctor_pass "${name} listening on port ${port}"
  else
    _doctor_fail "${name} not listening on port ${port}"
  fi
}

_doctor_check_backend() {
  if curl --silent --max-time 3 http://127.0.0.1:1337 >/dev/null 2>&1; then
    _doctor_pass "Decky backend responding on port 1337"
  else
    _doctor_fail "Decky backend not responding on port 1337"
  fi
}

_doctor_show_logs() {
  printf "%b█▓▒░ Recent Logs%b\n" "${CLR_BLUE}" "${CLR_NC}"
  _DOCTOR_OUTPUT+="\n=== Recent Logs ===\n"
  local logs
  if logs=$(journalctl -u plugin_loader -n 15 --no-pager 2>/dev/null) && [[ -n "${logs}" ]]; then
    printf "%s\n" "${logs}"
    _DOCTOR_OUTPUT+="${logs}\n"
  else
    _doctor_warn "No logs available"
  fi
}

doctor() {
  if [[ "${1:-}" == help ]]; then
    _msg 'Usage: doctor
  Diagnostic tool for an existing Decky installation.
  Checks: binary, service state, CEF debugging, port availability (1337, 8080),
  backend response, and shows recent logs.'
    return 0
  fi
  [[ $# -gt 0 ]] && _error "doctor takes no arguments."
  local -   # snapshot shell options; restored automatically on return
  set +e
  _DOCTOR_OUTPUT=""
  printf "%b█▓▒░ Decky Doctor%b\n" "${CLR_BLUE}" "${CLR_NC}"
  _DOCTOR_OUTPUT+="=== Decky Doctor ===\n"
  _doctor_info "Running Decky Loader health checks..."
  printf "\n"

  local plugin_loader="${HOMEBREW_FOLDER}/services/PluginLoader"

  _doctor_check \
    "PluginLoader binary found" \
    "PluginLoader binary not found" \
    test -f "${plugin_loader}"

  _doctor_check \
    "PluginLoader binary is executable" \
    "PluginLoader binary is not executable" \
    test -x "${plugin_loader}"

  _doctor_check_version

  _doctor_check \
    "Plugins directory exists" \
    "Plugins directory missing" \
    test -d "${HOMEBREW_FOLDER}/plugins"

  _doctor_check_cef

  _doctor_check \
    "plugin_loader.service installed" \
    "plugin_loader.service missing" \
    test -f "${PLUGIN_LOADER_SERVICE}"

  _doctor_check \
    "Service enabled" \
    "Service not enabled" \
    systemctl is-enabled plugin_loader.service >/dev/null 2>&1

  _doctor_check \
    "Service running" \
    "Service not running" \
    systemctl is-active plugin_loader.service >/dev/null 2>&1

  if _has_command pgrep; then
    _doctor_check \
      "PluginLoader process detected" \
      "PluginLoader process not detected" \
      pgrep -x PluginLoader >/dev/null 2>&1
  else
    _doctor_warn "pgrep not available, skipping process check"
  fi

  _doctor_check_port 1337 "Decky backend"
  _doctor_check_port 8080 "Steam CEF debugger"

  _doctor_check_backend

  _doctor_show_logs

  if [[ "${IS_GUI:-false}" == true ]] && _has_command zenity; then
    printf "%b" "${_DOCTOR_OUTPUT}" \
      | zenity --text-info --title="Decky Doctor" \
          --width=660 --height=520 \
          --font="monospace 10" \
          --ok-label="Close" 2>/dev/null || true
  fi
}

main "$@"
