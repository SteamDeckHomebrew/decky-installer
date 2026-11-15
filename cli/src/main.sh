usage() {
    printf 'Usage: %s [--user USER] [--help]%s\n' "$ENTRY_NAME" "$([[ $DEFAULT_OPERATION != choose ]] || printf ' [s|p|u]')"
    printf '%s\n' 'Install/update Decky Loader, or uninstall while retaining plugins and settings.' \
        'Run with Bash. Direct root invocation requires --user; sudo uses SUDO_USER.'
}

parse_args() {
    OPERATION=$DEFAULT_OPERATION; REQUESTED_USER=''
    local choice=''
    while (( $# )); do
        case $1 in
            --help|-h) usage; exit 0 ;;
            --user)
                (( $# >= 2 )) && [[ -n $2 && $2 != -* ]] || fail 2 '--user requires a username.'
                [[ -z $REQUESTED_USER ]] || fail 2 '--user may only be specified once.'
                REQUESTED_USER=$2; shift 2 ;;
            *)
                [[ $DEFAULT_OPERATION == choose && -z $choice && $1 != -* ]] || fail 2 "Unexpected argument: $1"
                choice=$1; shift ;;
        esac
    done
    if [[ $OPERATION == choose ]]; then
        if [[ -z $choice ]]; then
            if ! { exec 8<>/dev/tty; } 2>/dev/null; then fail 2 'No terminal is available. Pass s (stable), p (prerelease), or u (uninstall).'; fi
            while :; do
                printf 'Install stable/pre-release or uninstall (s/p/u): ' >&8
                IFS= read -r choice <&8 || fail 2 'No selection received.'
                case ${choice,,} in s*|p*|u*) break ;; *) printf 'Enter s, p, or u.\n' >&8 ;; esac
            done
            exec 8>&-
        fi
        case ${choice,,} in
            s*) OPERATION=release ;; p*) OPERATION=prerelease ;; u*) OPERATION=uninstall ;;
            *) fail 2 'Choose s (stable), p (prerelease), or u (uninstall).' ;;
        esac
    fi
}

user_markers() {
    local mode=$1 dir=$2 base marker index=0
    for base in "$TARGET_HOME/.steam/steam" "$TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
        index=$((index + 1)); marker=$base/.cef-enable-remote-debugging
        case $mode in
            create)
                [[ -d $base ]] || continue
                [[ ! -L $marker ]] || fail 3 "Refusing symlinked Steam debugging marker: $marker"
                if [[ ! -e $marker ]]; then
                    # Journal intent first, so a signal during creation can still clean it up.
                    printf '%s\n' "$marker" > "$dir/marker.$index"
                    touch -- "$marker" || fail 3 "Cannot enable Steam debugging in $base."
                fi ;;
            rollback)
                if [[ -f $dir/marker.$index ]]; then rm -f -- "$marker" || return 3; fi ;;
            remove) rm -f -- "$marker" || return 3 ;;
        esac
    done
}

prepare() {
    local operation=$1 user=$2 dir=$3
    resolve_user "$user"
    [[ $EUID == "$TARGET_UID" ]] || fail 3 'Preparation must run as the target user.'
    if [[ $operation != uninstall && ! -d $TARGET_HOME/.steam/steam && ! -d $TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam ]]; then
        fail 3 'Steam data directory was not found. Start Steam once as the target user, then retry.'
    fi
    [[ ! -L $TARGET_HOME/homebrew ]] || fail 3 'Refusing a symlinked homebrew directory.'
    mkdir -p -- "$TARGET_HOME/homebrew" || fail 3 'Cannot create homebrew.'
    if [[ $operation == uninstall ]]; then return; fi
    require_commands curl jq od stat sha256sum awk tr
    detect_arch
    log "Finding the latest $operation for $ARCH..."
    find_release "$operation" "$dir"
    log "Downloading Decky Loader $VERSION ($ASSET)..."
    network_get "$DOWNLOAD_URL" "$dir/PluginLoader" 600
    validate_binary "$dir/PluginLoader" "$SIZE" "$DIGEST" "$ARCH"
    [[ $DIGEST != none ]] || log 'Upstream supplies no SHA-256 digest; checked file size and ELF architecture only.'
    printf '%s\n' "$VERSION" > "$dir/version"
    printf '%s\n' "$SIZE" > "$dir/size"
    printf '%s\n' "$DIGEST" > "$dir/digest"
    [[ ! -L $TARGET_HOME/homebrew/plugins ]] || fail 3 'Refusing a symlinked plugins directory.'
    mkdir -p -- "$TARGET_HOME/homebrew/plugins" || fail 3 'Cannot create the plugins directory.'
}

emit_user_program() {
    printf 'set -Eeuo pipefail\numask 077\n'
    declare -f log fail unexpected_error require_commands resolve_user detect_arch validate_binary network_get find_release prepare user_markers
    printf "trap 'unexpected_error preparation \"\$LINENO\" \"\$?\"' ERR\n"
    # shellcheck disable=SC2016
    printf 'resolve_user "$2"\ncase "$1" in\nprepare) prepare "$4" "$2" "$3" ;;\n*) user_markers "$1" "$3" ;;\nesac\n'
}

as_user() {
    local command=$1
    if (( EUID == 0 )); then
        emit_user_program | sudo -u "$TARGET_USER" \
            --preserve-env=http_proxy,https_proxy,all_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,ALL_PROXY,NO_PROXY \
            -- bash -s -- "$command" "$TARGET_USER" "$WORK" "$OPERATION"
    elif [[ $command == prepare ]]; then prepare "$OPERATION" "$TARGET_USER" "$WORK"
    else user_markers "$command" "$WORK"; fi
}

main_cleanup() {
    local code=$?
    trap - EXIT INT TERM HUP
    if [[ -n ${WORK:-} ]]; then
        if ! rm -rf -- "$WORK"; then
            printf '[decky] ERROR: Could not clean temporary directory: %s\n' "$WORK" >&2
            (( code != 0 )) || code=3
        fi
    fi
    exit "$code"
}

main() {
    set -Eeuo pipefail
    trap 'unexpected_error installer "$LINENO" "$?"' ERR
    umask 077
    parse_args "$@"
    require_commands getent realpath id sudo mktemp rm mkdir bash
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || fail 3 'Decky requires Linux with a running systemd manager.'
    if [[ -z $REQUESTED_USER ]]; then
        if (( EUID == 0 )); then
            REQUESTED_USER=${SUDO_USER:-}
            [[ -n $REQUESTED_USER ]] || fail 2 'Direct root invocation requires --user USER.'
        else REQUESTED_USER=$(id -un); fi
    fi
    resolve_user "$REQUESTED_USER"
    (( EUID == 0 || EUID == TARGET_UID )) || fail 3 'Installing for another user requires an explicit sudo/root invocation.'
    WORK=''
    trap main_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    WORK=$(mktemp -d /tmp/decky-installer.XXXXXXXX) || fail 3 'Cannot create a temporary download directory.'
    if (( EUID == 0 )); then chown "$TARGET_UID:$TARGET_GID" "$WORK" || fail 3 'Cannot assign preparation directory ownership.'; fi
    as_user prepare
    local version=none size=0 digest=none code=0
    if [[ $OPERATION != uninstall ]]; then
        version=$(cat "$WORK/version"); size=$(cat "$WORK/size"); digest=$(cat "$WORK/digest")
    fi
    # Acquire authorization before touching Steam markers. stdin is never a password source.
    local -a elevate=(sudo)
    if (( EUID != 0 )); then
        if ! { exec 8<>/dev/tty; } 2>/dev/null; then elevate+=(-n); else exec 8>&-; fi
        "${elevate[@]}" -v || fail 3 'Administrator authorization failed. Run in a terminal or configure noninteractive sudo.'
    fi
    log "Applying $OPERATION (system operations require administrator privileges)..."
    if (( EUID == 0 )); then
        emit_worker | bash -s -- "$OPERATION" "$TARGET_USER" "$WORK/PluginLoader" "$version" "$size" "$digest" || code=$?
    else
        emit_worker | "${elevate[@]}" -- bash -s -- "$OPERATION" "$TARGET_USER" "$WORK/PluginLoader" "$version" "$size" "$digest" || code=$?
    fi
    if (( code != 0 )); then
        (( code != 1 )) || code=3
        fail "$code" 'Deployment did not complete. See the specific error above.'
    fi
    log 'Done. Plugins and settings have been retained.'
}
