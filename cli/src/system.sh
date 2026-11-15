# These functions are serialized into a separate privileged process. No network code
# is included. The worker re-resolves identity and validates its inputs independently.
# Functions are called in the serialized worker process, outside ShellCheck's call graph.
# shellcheck disable=SC2329
worker_define() {
    worker_markers() {
        {
            printf 'set -Eeuo pipefail\n'
            declare -f fail resolve_user user_markers
            # shellcheck disable=SC2016
            printf 'resolve_user "$1"\nuser_markers "$2" "$3"\n'
        } | sudo -u "$TARGET_USER" -- bash -s -- "$TARGET_USER" "$1" "$W_WORK"
    }
    worker_ctl() { timeout 60s systemctl "$@"; }
    worker_user_ctl() {
        timeout 60s sudo -u "$TARGET_USER" -- env "XDG_RUNTIME_DIR=/run/user/$TARGET_UID" systemctl --user "$@"
    }
    worker_service_state() {
        W_ACTIVE=$(worker_ctl is-active plugin_loader.service 2>/dev/null) || W_ACTIVE=inactive
        W_ENABLED=$(worker_ctl is-enabled plugin_loader.service 2>/dev/null) || :
        case $W_ENABLED in
            enabled|enabled-runtime|disabled|static|indirect|not-found|'') ;;
            *) fail 3 "Unsupported existing service state: $W_ENABLED. Resolve it before installing." ;;
        esac
        W_USER_ACTIVE=inactive; W_USER_ENABLED=disabled; W_USER_PRESENT=0
        if [[ -e $TARGET_HOME/.config/systemd/user/plugin_loader.service || -L $TARGET_HOME/.config/systemd/user/plugin_loader.service ]]; then
            worker_user_ctl show-environment >/dev/null 2>&1 || fail 3 'A legacy user service exists, but its user systemd manager is unavailable. Start a user session and retry.'
            W_USER_PRESENT=1
            W_USER_ACTIVE=$(worker_user_ctl is-active plugin_loader.service 2>/dev/null) || W_USER_ACTIVE=inactive
            W_USER_ENABLED=$(worker_user_ctl is-enabled plugin_loader.service 2>/dev/null) || :
            case $W_USER_ENABLED in enabled|enabled-runtime|disabled|static|indirect|'') ;; *) fail 3 'Unsupported legacy user service state.' ;; esac
        fi
    }
    worker_unit() {
        local path executable working level=INFO extra=''
        path=$(systemd_escape "$TARGET_HOME/homebrew")
        executable=${path//\$/\$\$}
        # WorkingDirectory takes the complete value, not shell-style quoted words.
        working=${TARGET_HOME//%/%%}/homebrew
        if [[ $W_OPERATION == prerelease ]]; then level=DEBUG; extra=$'KillMode=process\nTimeoutStopSec=15'; fi
        cat <<EOF
[Unit]
Description=SteamDeck Plugin Loader
After=network.target
[Service]
Type=simple
User=root
Restart=always
ExecStart="$executable/services/PluginLoader"
WorkingDirectory=$working/services
Environment="UNPRIVILEGED_PATH=$path"
Environment="PRIVILEGED_PATH=$path"
Environment=LOG_LEVEL=$level
$extra
[Install]
WantedBy=multi-user.target
EOF
    }
    worker_restore_enabled() {
        local state=$1 kind=$2
        if [[ $state == enabled ]]; then
            "$kind" enable plugin_loader.service
        elif [[ $state == enabled-runtime ]]; then
            "$kind" enable --runtime plugin_loader.service
        fi
    }
    worker_rollback() {
        local failed=0
        log 'Restoring the previous installation and service state...'
        if [[ -e $W_UNIT || $W_ACTIVE == active ]]; then
            worker_ctl stop plugin_loader.service >/dev/null 2>&1 || failed=1
            worker_ctl disable plugin_loader.service >/dev/null 2>&1 || failed=1
        fi
        if (( W_REPLACED )); then
            rm -rf -- services || failed=1
        fi
        if [[ -d $W_BACKUP/services ]]; then mv -T -- "$W_BACKUP/services" services || failed=1; fi
        if (( W_UNIT_CHANGED )); then
            rm -f -- "$W_UNIT" || failed=1
            if (( W_HAD_UNIT )); then cp -a -- "$W_BACKUP/unit" "$W_UNIT" || failed=1; fi
        fi
        worker_ctl daemon-reload || failed=1
        worker_restore_enabled "$W_ENABLED" worker_ctl || failed=1
        if [[ $W_ACTIVE == active ]]; then
            worker_ctl reset-failed plugin_loader.service || failed=1
            worker_ctl start plugin_loader.service || failed=1
        fi
        if (( W_USER_PRESENT )); then
            if [[ -e $W_BACKUP/user-unit || -L $W_BACKUP/user-unit ]]; then
                cp -a -- "$W_BACKUP/user-unit" "$TARGET_HOME/.config/systemd/user/plugin_loader.service" || failed=1
            fi
            worker_user_ctl daemon-reload || failed=1
            worker_restore_enabled "$W_USER_ENABLED" worker_user_ctl || failed=1
            if [[ $W_USER_ACTIVE == active ]]; then worker_user_ctl start plugin_loader.service || failed=1; fi
        fi
        return "$failed"
    }
    worker_exit() {
        local code=$?
        trap - EXIT INT TERM HUP
        if (( W_TRANSACTION )); then
            # A signal or explicit failure must never turn into success.
            (( code != 0 )) || code=6
            if ! worker_rollback; then
                printf '[decky] ERROR: Rollback failed. Recovery files: %s/%s; system service: %s. Preserve these files and inspect journalctl -u plugin_loader.service.\n' "$TARGET_HOME/homebrew" "$W_BACKUP" "$W_UNIT" >&2
                code=7
                W_KEEP=1
            fi
        fi
        if (( W_MARKERS && ! W_COMMITTED )); then
            worker_markers rollback || { printf '[decky] ERROR: Cannot restore Steam debugging markers.\n' >&2; code=7; }
        fi
        local directory
        local -a cleanup=("$W_STAGE" "$W_PRIVATE")
        (( W_KEEP )) || cleanup+=("$W_BACKUP")
        for directory in "${cleanup[@]}"; do
            [[ -n $directory ]] || continue
            if ! rm -rf -- "$directory"; then
                printf '[decky] ERROR: Cannot remove deployment temporary directory: %s\n' "$directory" >&2
                (( code != 0 )) || code=3
            fi
        done
        exit "$code"
    }
    worker_check_live() {
        local i
        # Require an active process with no automatic restarts throughout the window.
        for ((i=0; i<5; i++)); do
            sleep 1
            worker_ctl is-active --quiet plugin_loader.service || return 1
            [[ $(worker_ctl show -p NRestarts --value plugin_loader.service) == 0 ]] || return 1
        done
    }
    worker_deploy() {
        local had_services=0
        worker_service_state
        W_BACKUP=$(mktemp -d .decky-backup.XXXXXXXX) || fail 6 'Cannot create rollback directory.'
        if [[ -e $W_UNIT ]]; then
            cp -a -- "$W_UNIT" "$W_BACKUP/unit" || fail 6 'Cannot back up the system service.'
            W_HAD_UNIT=1
        fi
        if (( W_USER_PRESENT )); then
            cp -a -- "$TARGET_HOME/.config/systemd/user/plugin_loader.service" "$W_BACKUP/user-unit" || fail 6 'Cannot back up the legacy service.'
        fi
        [[ ! -e services ]] || had_services=1
        W_TRANSACTION=1
        if [[ $W_ACTIVE == active || $W_HAD_UNIT == 1 ]]; then
            worker_ctl stop plugin_loader.service || fail 6 'Could not stop the existing system service.'
            worker_ctl disable plugin_loader.service || fail 6 'Could not disable the existing system service.'
        fi
        if (( W_USER_PRESENT )); then
            worker_user_ctl stop plugin_loader.service || fail 6 'Could not stop the legacy user service.'
            worker_user_ctl disable plugin_loader.service || fail 6 'Could not disable the legacy user service.'
            rm -f -- "$TARGET_HOME/.config/systemd/user/plugin_loader.service" || fail 6 'Could not remove the legacy service.'
            worker_user_ctl daemon-reload || fail 6 'Could not reload the user service manager.'
        fi
        if (( had_services )); then
            mv -T -- services "$W_BACKUP/services" || fail 6 'Could not preserve the previous services directory.'
        fi
        W_UNIT_CHANGED=1
        if [[ $W_OPERATION == uninstall ]]; then
            # Retain unrelated services data, version records and template archives.
            if (( had_services )); then
                W_REPLACED=1
                cp -a -- "$W_BACKUP/services" services || fail 6 'Cannot prepare retained service data.'
                rm -f -- services/PluginLoader || fail 6 'Cannot remove the Loader binary.'
            fi
            rm -f -- "$W_UNIT" || fail 6 'Cannot remove the system service.'
        else
            W_REPLACED=1
            mv -T -- "$W_STAGE" services || fail 6 'Cannot activate the prepared service files.'
            W_STAGE=''; W_REPLACED=1
            install -m 0644 -- services/.systemd/plugin_loader.service "$W_UNIT" || fail 6 'Cannot install the system service.'
        fi
        worker_ctl daemon-reload || fail 6 'systemd configuration reload failed.'
        if [[ $W_OPERATION != uninstall ]]; then
            # A freshly installed inactive unit may not have been loaded yet.
            worker_ctl reset-failed plugin_loader.service 2>/dev/null || :
            worker_ctl enable plugin_loader.service || fail 6 'Could not enable startup of Decky Loader.'
            worker_ctl start plugin_loader.service || fail 6 'Decky Loader failed to start. Inspect journalctl -u plugin_loader.service.'
            worker_check_live || fail 6 'Decky Loader did not remain running. Inspect journalctl -u plugin_loader.service.'
        fi
        W_TRANSACTION=0
        W_COMMITTED=1
        if [[ $W_OPERATION == uninstall ]]; then
            worker_markers remove || fail 3 'Loader was removed, but Steam debugging markers could not be removed. Check their permissions.'
        fi
        log 'System deployment completed.'
    }
    worker_main() {
        [[ $EUID == 0 ]] || fail 3 'The deployment worker requires root privileges.'
        W_OPERATION=$1
        case $W_OPERATION in release|prerelease|uninstall) ;; *) fail 2 'Invalid worker operation.' ;; esac
        resolve_user "$2"
        local source=$3 version=$4 size=$5 digest=$6
        W_WORK=${source%/*}; W_MARKERS=0; W_COMMITTED=0
        W_UNIT=/etc/systemd/system/plugin_loader.service
        W_PRIVATE=''; W_STAGE=''; W_BACKUP=''; W_TRANSACTION=0; W_KEEP=0
        W_REPLACED=0; W_HAD_UNIT=0; W_UNIT_CHANGED=0
        trap worker_exit EXIT
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        require_commands flock timeout systemctl install cp mv rm mktemp realpath stat od tr sha256sum
        # /run/lock can be world-writable; use a private root-owned directory instead.
        [[ ! -L /run/decky-installer ]] || fail 3 'Unsafe lock directory.'
        install -d -m 0700 -o root -g root /run/decky-installer || fail 3 'Cannot create the installation lock directory.'
        exec 9>/run/decky-installer/lock
        flock -n 9 || fail 3 'Another Decky installation or uninstall is in progress. Retry when it finishes.'
        [[ ! -L $TARGET_HOME/homebrew ]] || fail 3 'Refusing a symlinked homebrew directory.'
        [[ -d $TARGET_HOME/homebrew ]] || fail 3 'The prepared homebrew directory is missing.'
        cd -- "$TARGET_HOME/homebrew" || fail 3 'Cannot access homebrew.'
        [[ ! -L services && ( ! -e services || -d services ) ]] || fail 3 'The services path must be a real directory.'
        [[ ! -L $W_UNIT && ( ! -e $W_UNIT || -f $W_UNIT ) ]] || fail 3 'The system service path must be a regular file.'
        [[ $(realpath -e /etc/systemd/system) == /etc/systemd/system ]] || fail 3 'Symlinked system service directories are not supported.'
        local legacy_parent=$TARGET_HOME/.config/systemd/user
        if [[ -d $legacy_parent ]]; then
            [[ $(realpath -e -- "$legacy_parent") == "$legacy_parent" ]] || fail 3 'Symlinked legacy service directories are not supported.'
        fi
        if [[ $W_OPERATION != uninstall ]]; then
            [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || fail 5 'Invalid version passed to deployment.'
            [[ -f $source && ! -L $source ]] || fail 5 'The prepared binary is missing or is a symlink.'
            W_PRIVATE=$(mktemp -d /run/decky-installer/asset.XXXXXXXX) || fail 6 'Cannot create private deployment staging.'
            cp -P -- "$source" "$W_PRIVATE/PluginLoader" || fail 6 'Cannot copy the prepared binary.'
            detect_arch
            validate_binary "$W_PRIVATE/PluginLoader" "$size" "$digest" "$ARCH"
            W_STAGE=$(mktemp -d .decky-stage.XXXXXXXX) || fail 6 'Cannot create service staging.'
            chmod 0755 "$W_STAGE"
            install -m 0755 -- "$W_PRIVATE/PluginLoader" "$W_STAGE/PluginLoader" || fail 6 'Cannot stage the executable.'
            if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
                chcon -t bin_t "$W_STAGE/PluginLoader" || fail 6 'Cannot set the required SELinux binary label.'
            fi
            printf '%s\n' "$version" > "$W_STAGE/.loader.version"
            mkdir "$W_STAGE/.systemd"
            worker_unit > "$W_STAGE/.systemd/plugin_loader.service"
        fi
        if [[ $W_OPERATION != uninstall ]]; then
            # Marker changes are serialized with deployment, including their rollback.
            W_MARKERS=1
            worker_markers create || { worker_markers rollback || :; fail 3 'Cannot enable Steam debugging.'; }
        fi
        worker_deploy
    }
}

emit_worker() {
    printf 'set -Eeuo pipefail\numask 022\n'
    declare -f log fail unexpected_error require_commands resolve_user detect_arch validate_binary systemd_escape worker_define user_markers
    printf "trap 'unexpected_error deployment \"\$LINENO\" \"\$?\"' ERR\n"
    printf 'worker_define\nworker_main "$@"\n'
}
