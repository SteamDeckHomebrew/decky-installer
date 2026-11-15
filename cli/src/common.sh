# Shared primitives. Modules define functions only; the generated entrypoint calls main.
log() { printf '[decky] %s\n' "$*"; }
fail() { local code=$1; shift; printf '[decky] ERROR: %s\n' "$*" >&2; exit "$code"; }
unexpected_error() {
    printf '[decky] ERROR: Unexpected failure in %s (line %s, exit %s). Check disk space and permissions.\n' "$1" "$2" "$3" >&2
    exit 6
}

require_commands() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || fail 3 "Required command '$name' is missing. Install it and retry."
    done
}

resolve_user() {
    local record
    record=$(getent passwd "$1") || fail 3 "Unknown user: $1"
    IFS=: read -r TARGET_USER _ TARGET_UID TARGET_GID _ TARGET_HOME _ <<< "$record"
    [[ $TARGET_UID =~ ^[0-9]+$ && $TARGET_UID != 0 && $TARGET_HOME == /* && $TARGET_HOME != / ]] ||
        fail 3 'The target must be a non-root user with an absolute home directory.'
    [[ $TARGET_HOME != *$'\n'* && $TARGET_HOME != *$'\r'* ]] || fail 3 'Unsupported home directory.'
    [[ -d $TARGET_HOME && ! -L $TARGET_HOME ]] || fail 3 'The home directory must exist and must not be a symlink.'
    [[ $(realpath -e -- "$TARGET_HOME") == "$TARGET_HOME" ]] || fail 3 'Symlinked home paths are not supported.'
}

detect_arch() {
    case $(uname -m) in
        x86_64) ARCH=x86_64; ASSET=PluginLoader ;;
        aarch64|arm64) ARCH=arm64; ASSET=PluginLoader-arm64 ;;
        *) fail 3 "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

validate_binary() {
    local file=$1 size=$2 digest=$3 arch=$4 actual header machine
    [[ -f $file && ! -L $file && $size =~ ^[1-9][0-9]*$ ]] || fail 5 'Invalid binary file or asset size.'
    actual=$(stat -c %s -- "$file") || fail 5 'Cannot inspect downloaded binary.'
    [[ $actual == "$size" ]] || fail 5 "Incomplete download: expected $size bytes, received $actual. Retry the download."
    header=$(od -An -tx1 -N6 -- "$file" | tr -d ' \n')
    machine=$(od -An -tx1 -j18 -N2 -- "$file" | tr -d ' \n')
    [[ $header == 7f454c460201 ]] || fail 5 'Downloaded asset is not a little-endian 64-bit ELF executable.'
    case "$arch:$machine" in
        x86_64:3e00|arm64:b700) ;;
        *) fail 5 "Downloaded ELF does not match $arch." ;;
    esac
    if [[ $digest != none ]]; then
        [[ $digest =~ ^sha256:[[:xdigit:]]{64}$ ]] || fail 5 'Unsupported or invalid asset digest.'
        actual=$(sha256sum -- "$file"); actual=${actual%% *}
        [[ ${actual,,} == "${digest#sha256:}" ]] || fail 5 'SHA-256 mismatch. The downloaded asset was rejected.'
    fi
}

systemd_escape() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//%/%%}
    printf '%s' "$value"
}
