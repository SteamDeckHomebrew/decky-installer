#!/usr/bin/env bash

set -u

VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS="${GREEN}[PASS]${NC}"
FAIL="${RED}[FAIL]${NC}"
WARN="${YELLOW}[WARN]${NC}"
INFO="${CYAN}[INFO]${NC}"

HOMEBREW="${HOME}/homebrew"
PLUGIN_LOADER="${HOMEBREW}/services/PluginLoader"

main() {
    header

    info "Running Decky Loader health checks..."
    printf "\n"

    check \
        "PluginLoader binary found" \
        "PluginLoader binary not found" \
        test -f "$PLUGIN_LOADER"

    check \
        "PluginLoader binary is executable" \
        "PluginLoader binary is not executable" \
        test -x "$PLUGIN_LOADER"

    check_version

    check \
        "Plugins directory exists" \
        "Plugins directory missing" \
        test -d "${HOMEBREW}/plugins"

    check_cef_debugging

    check \
        "plugin_loader.service installed" \
        "plugin_loader.service missing" \
        test -f /etc/systemd/system/plugin_loader.service

    check \
        "Service enabled" \
        "Service not enabled" \
        systemctl is-enabled plugin_loader.service >/dev/null 2>&1

    check \
        "Service running" \
        "Service not running" \
        systemctl is-active plugin_loader.service >/dev/null 2>&1

    check \
        "PluginLoader process detected" \
        "PluginLoader process not detected" \
        pgrep -x PluginLoader >/dev/null 2>&1

    check_port 1337 "Decky backend"
    check_port 8080 "Steam CEF debugger"

    check_decky_backend

    show_logs
}

pass() {
    printf "%b %s\n" "${PASS}" "$*"
}

fail() {
    printf "%b %s\n" "${FAIL}" "$*"
}

warn() {
    printf "%b %s\n" "${WARN}" "$*"
}

info() {
    printf "%b %s\n" "${INFO}" "$*"
}

header() {
    printf "%b█▓▒░ Decky Doctor%b\n" "${BLUE}" "${NC}"
}

usage() {
    cat <<EOF
Decky Doctor - System health checker

Usage:
  $(basename "$0") [options]

Options:
  -h, --help       Show this help message
  -v, --version    Show version

Run without options to perform health checks.
EOF
}

show_version() {
    printf "Decky Doctor version %s\n" "$VERSION"
}

check() {
    local success_msg="$1"
    local fail_msg="$2"

    shift 2

    if "$@"; then
        pass "$success_msg"
    else
        fail "$fail_msg"
    fi
}

check_version() {
    local version_file="${HOMEBREW}/services/.loader.version"

    if [ -f "$version_file" ]; then
        pass "Installed version: $(<"$version_file")"
    else
        fail "Version file missing"
    fi
}

check_cef_debugging() {
    local steam_path="${HOME}/.steam/steam/.cef-enable-remote-debugging"
    local flatpak_path="${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"

    if [ -f "$steam_path" ] || [ -f "$flatpak_path" ]; then
        pass "CEF remote debugging enabled"
    else
        warn "CEF remote debugging file not found"
    fi
}

check_port() {
    local port="$1"
    local name="$2"

    if ss -ltn "( sport = :$port )" | grep -q . ; then
        pass "$name listening on port $port"
    else
        fail "$name not listening on port $port"
    fi
}

check_decky_backend() {
    if curl \
        --silent \
        --max-time 3 \
        http://127.0.0.1:1337 \
        >/dev/null 2>&1; then
        pass "Decky backend responding on port 1337"
    else
        fail "Decky backend not responding on port 1337"
    fi
}

show_logs() {
    printf "%b\n" "${BLUE}█▓▒░ Recent Logs${NC}"

    journalctl -u plugin_loader -n 15 --no-pager 2>/dev/null ||
        warn "No logs available"
}

# --- CLI handling ---
case "${1:-}" in
    -h|--help)
        usage
        ;;
    -v|--version)
        show_version
        ;;
    "")
        main
        ;;
    *)
        printf "Unknown option: %s\n\n" "$1"
        usage
        exit 1
        ;;
esac
