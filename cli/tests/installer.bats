#!/usr/bin/env bats

setup() {
    ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
    for module in common network system main; do source "$ROOT/cli/src/$module.sh"; done
    worker_define
    TEST_DIR=$BATS_TEST_TMPDIR
    TARGET_HOME="$TEST_DIR/home with spaces"
    mkdir -p "$TARGET_HOME/homebrew" "$TEST_DIR/work"
    TARGET_USER=tester; TARGET_UID=1000
    export TEST_DIR
}

make_elf() {
    { printf '\177ELF\002\001'; head -c 12 /dev/zero; printf '\076\000'; head -c 44 /dev/zero; } > "$1"
}

mock_network() {
    sleep() { :; }
    curl() {
        local file='' headers='' n=0
        while (( $# )); do
            case $1 in --output) file=$2; shift ;; --dump-header) headers=$2; shift ;; esac
            shift
        done
        [[ ! -f $TEST_DIR/calls ]] || read -r n < "$TEST_DIR/calls"
        n=$((n + 1)); printf '%s' "$n" > "$TEST_DIR/calls"
        printf '%s\r\n' "${HEADERS:-}" > "$headers"
        printf '%s' "${BODY:-payload}" > "$file"
        if [[ ${RECOVER:-no} == yes && $n == 3 ]]; then printf 200; return 0; fi
        printf '%s' "${HTTP:-200}"
        return "${CURL_CODE:-0}"
    }
}

fixture_deploy() {
    cd "$TARGET_HOME/homebrew"
    mkdir -p services "$TEST_DIR/stage/.systemd"
    printf old > services/PluginLoader
    printf retained > services/extra
    printf new > "$TEST_DIR/stage/PluginLoader"
    printf new-unit > "$TEST_DIR/stage/.systemd/plugin_loader.service"
    W_STAGE=$TEST_DIR/stage; W_UNIT=$TEST_DIR/unit
    printf old-unit > "$W_UNIT"
    W_OPERATION=release; W_PRIVATE=''; W_BACKUP=''; W_TRANSACTION=0
    W_KEEP=0; W_REPLACED=0; W_HAD_UNIT=0; W_UNIT_CHANGED=0
    W_MARKERS=0; W_COMMITTED=0
    worker_service_state() { W_ACTIVE=active; W_ENABLED=enabled; W_USER_PRESENT=0; }
    worker_ctl() {
        printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
        if [[ $1 == start && ${FAIL_START:-no} == yes && $(cat services/PluginLoader) == new ]]; then return 1; fi
        return 0
    }
    worker_check_live() { [[ ${FAIL_LIVE:-no} == no ]]; }
    worker_markers() { :; }
}

transaction() {
    trap worker_exit EXIT
    trap 'exit 130' INT
    worker_deploy
    exit 0
}

@test "all four generated scripts execute from files and pipes" {
    for file in "$ROOT"/cli/dist/*.sh; do
        run bash "$file" --help
        [ "$status" -eq 0 ]
        [[ $output == *Usage:* ]]
        run bash -c 'cat "$1" | bash -s -- --help' _ "$file"
        [ "$status" -eq 0 ]
        [[ $output == *Usage:* ]]
    done
}

@test "truncated stream does not execute even the first statement" {
    run bash -c 'head -n -1 "$1" | bash -s -- --help' _ "$ROOT/cli/dist/install_release.sh"
    [ "$status" -ne 0 ]
    [[ $output != *Usage:* ]]
}

@test "updater accepts historical case-insensitive prefixes and rejects invalid input" {
    DEFAULT_OPERATION=choose
    parse_args STABLE; [ "$OPERATION" = release ]
    parse_args prerelease; [ "$OPERATION" = prerelease ]
    parse_args U; [ "$OPERATION" = uninstall ]
    run parse_args nonsense
    [ "$status" -eq 2 ]
}

@test "missing username is an argument error" {
    run bash "$ROOT/cli/dist/install_release.sh" --user
    [ "$status" -eq 2 ]
}

@test "worker payload parses independently and rejects unprivileged execution" {
    emit_worker > "$TEST_DIR/worker"
    run bash -n "$TEST_DIR/worker"
    [ "$status" -eq 0 ]
    if (( EUID != 0 )); then
        run bash "$TEST_DIR/worker" release tester nowhere v1 64 none
        [ "$status" -eq 3 ]
    fi
}

@test "network retries transient failures with a bounded attempt count" {
    mock_network; CURL_CODE=7; HTTP=000
    run network_get https://github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 4 ]; [[ $output == *'Cannot connect'* ]]
    [ "$(cat "$TEST_DIR/calls")" = 3 ]
    [ ! -e "$TEST_DIR/asset" ]
}

@test "network can recover on its final attempt" {
    mock_network; CURL_CODE=28; HTTP=000; RECOVER=yes
    run network_get https://github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 0 ]; [ "$(cat "$TEST_DIR/asset")" = payload ]
    [ "$(cat "$TEST_DIR/calls")" = 3 ]
}

@test "DNS TLS timeout and disk failures have distinct explanations" {
    mock_network
    for pair in '6:DNS' '60:TLS' '28:timed out' '23:disk space'; do
        CURL_CODE=${pair%%:*}; HTTP=000
        run network_get https://github.com/example "$TEST_DIR/asset" 60
        [[ $output == *"${pair#*:}"* ]]
        if [[ $CURL_CODE == 23 ]]; then [ "$status" -eq 3 ]; else [ "$status" -eq 4 ]; fi
    done
}

@test "HTTP 404 is not retried and response credentials are not printed" {
    mock_network; HTTP=404; BODY='secret-token'
    run network_get https://github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 4 ]; [[ $output == *'HTTP 404'* && $output != *secret-token* ]]
    [ "$(cat "$TEST_DIR/calls")" = 1 ]
}

@test "GitHub exhaustion and long Retry-After fail promptly" {
    mock_network; HTTP=403; HEADERS=$'x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 123456'
    run network_get https://api.github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 4 ]; [[ $output == *'rate limit exhausted'* && $output == *123456* ]]
    [ "$(cat "$TEST_DIR/calls")" = 1 ]
    HTTP=429; HEADERS='Retry-After: 3600'
    run network_get https://api.github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 4 ]; [[ $output == *'delayed retry'* ]]
}

@test "HTTP 429 and server errors retry but TLS errors do not" {
    mock_network
    for HTTP in 429 500 502 503 504; do
        rm -f "$TEST_DIR/calls"
        run network_get https://github.com/example "$TEST_DIR/asset" 60
        [ "$status" -eq 4 ]; [ "$(cat "$TEST_DIR/calls")" = 3 ]
    done
    rm -f "$TEST_DIR/calls"; CURL_CODE=60
    run network_get https://github.com/example "$TEST_DIR/asset" 60
    [ "$status" -eq 4 ]; [ "$(cat "$TEST_DIR/calls")" = 1 ]
}

@test "release parsing rejects non-JSON, missing assets and duplicate assets" {
    mock_network; ASSET=PluginLoader
    for BODY in 'not json' '[]' '[{"draft":false,"prerelease":false,"tag_name":"v1","assets":[]}]'; do
        run find_release release "$TEST_DIR"
        [ "$status" -eq 5 ]
    done
    BODY='[{"draft":false,"prerelease":false,"tag_name":"v1","assets":[{"name":"PluginLoader"},{"name":"PluginLoader"}]}]'
    run find_release release "$TEST_DIR"
    [ "$status" -eq 5 ]
}

@test "release selection separates channels and ARM64 resource names" {
    mock_network; ASSET=PluginLoader-arm64
    BODY='[{"draft":false,"prerelease":true,"tag_name":"v2-pre","assets":[{"name":"PluginLoader-arm64","size":64,"browser_download_url":"https://github.com/SteamDeckHomebrew/decky-loader/releases/download/v2/PluginLoader-arm64"}]},{"draft":false,"prerelease":false,"tag_name":"v1","assets":[{"name":"PluginLoader-arm64","size":64,"browser_download_url":"https://github.com/SteamDeckHomebrew/decky-loader/releases/download/v1/PluginLoader-arm64"}]}]'
    find_release release "$TEST_DIR"; [ "$VERSION" = v1 ]; [ "$DIGEST" = none ]
    find_release prerelease "$TEST_DIR"; [ "$VERSION" = v2-pre ]
}

@test "ELF validation rejects truncated, wrong-architecture and altered files" {
    make_elf "$TEST_DIR/binary"
    run validate_binary "$TEST_DIR/binary" 64 none x86_64
    [ "$status" -eq 0 ]
    run validate_binary "$TEST_DIR/binary" 65 none x86_64
    [ "$status" -eq 5 ]; [[ $output == *'Incomplete download'* ]]
    run validate_binary "$TEST_DIR/binary" 64 none arm64
    [ "$status" -eq 5 ]; [[ $output == *'does not match'* ]]
    run validate_binary "$TEST_DIR/binary" 64 "sha256:$(printf '%064d' 0)" x86_64
    [ "$status" -eq 5 ]; [[ $output == *'SHA-256 mismatch'* ]]
    local digest; digest=$(sha256sum "$TEST_DIR/binary"); digest=${digest%% *}
    run validate_binary "$TEST_DIR/binary" 64 "sha256:$digest" x86_64
    [ "$status" -eq 0 ]
}

@test "unknown architecture and symlinked binaries are rejected" {
    uname() { printf riscv64; }
    run detect_arch
    [ "$status" -eq 3 ]
    make_elf "$TEST_DIR/binary"; ln -s binary "$TEST_DIR/link"
    run validate_binary "$TEST_DIR/link" 64 none x86_64
    [ "$status" -eq 5 ]
}

@test "successful deployment replaces services and retains plugin data" {
    fixture_deploy; mkdir plugins; printf kept > plugins/data
    run transaction
    [ "$status" -eq 0 ]; [ "$(cat services/PluginLoader)" = new ]
    [ "$(cat plugins/data)" = kept ]; [ "$(cat "$W_UNIT")" = new-unit ]
}

@test "failed startup rolls back the binary unit and enabled state" {
    fixture_deploy; FAIL_START=yes
    run transaction
    [ "$status" -eq 6 ]; [[ $output == *Restoring* ]]
    [ "$(cat services/PluginLoader)" = old ]; [ "$(cat "$W_UNIT")" = old-unit ]
    [[ $(cat "$TEST_DIR/systemctl.log") == *'enable plugin_loader.service'* ]]
}

@test "fresh installation health failure removes the new deployment" {
    fixture_deploy; rm -rf services; rm "$W_UNIT"; FAIL_LIVE=yes
    worker_service_state() { W_ACTIVE=inactive; W_ENABLED=not-found; W_USER_PRESENT=0; }
    run transaction
    [ "$status" -eq 6 ]; [ ! -e services ]; [ ! -e "$W_UNIT" ]
}

@test "rollback failure preserves recovery files and returns exit 7" {
    fixture_deploy; FAIL_START=yes
    worker_rollback() { return 1; }
    run transaction
    [ "$status" -eq 7 ]; [[ $output == *'Recovery files:'* ]]
    [ "$(cat .decky-backup.*/services/PluginLoader)" = old ]
}

@test "SIGINT during health check rolls back and returns 130" {
    fixture_deploy
    worker_check_live() { kill -INT "$BASHPID"; return 1; }
    run transaction
    [ "$status" -eq 130 ]; [ "$(cat services/PluginLoader)" = old ]
}

@test "uninstall retains unrelated data and is repeatable" {
    fixture_deploy; W_OPERATION=uninstall; mkdir plugins; printf settings > plugins/data
    run transaction
    [ "$status" -eq 0 ]; [ ! -e services/PluginLoader ]; [ ! -e "$W_UNIT" ]
    [ "$(cat services/extra)" = retained ]; [ "$(cat plugins/data)" = settings ]
    worker_service_state() { W_ACTIVE=inactive; W_ENABLED=not-found; W_USER_PRESENT=0; }
    run transaction
    [ "$status" -eq 0 ]; [ ! -e services/PluginLoader ]
}

@test "marker rollback removes only newly created markers" {
    mkdir -p "$TARGET_HOME/.steam/steam" "$TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    touch "$TARGET_HOME/.steam/steam/.cef-enable-remote-debugging"
    user_markers create "$TEST_DIR/work"
    user_markers rollback "$TEST_DIR/work"
    [ -f "$TARGET_HOME/.steam/steam/.cef-enable-remote-debugging" ]
    [ ! -e "$TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging" ]
}

@test "unit generation quotes spaces and escapes percent expansion" {
    TARGET_HOME='/home/a b%name'; W_OPERATION=prerelease
    run worker_unit
    [ "$status" -eq 0 ]
    [[ $output == *'ExecStart="/home/a b%%name/homebrew/services/PluginLoader"'* ]]
    [[ $output == *'LOG_LEVEL=DEBUG'* && $output == *'TimeoutStopSec=15'* ]]
}

@test "pagination finds a channel beyond the first hundred releases" {
    ASSET=PluginLoader
    network_get() {
        if [[ $1 == *'page=1' ]]; then
            jq -n '[range(100) | {draft:false, prerelease:true}]' > "$2"
        else
            printf '%s' '[{"draft":false,"prerelease":false,"tag_name":"v1","assets":[{"name":"PluginLoader","size":64,"browser_download_url":"https://github.com/SteamDeckHomebrew/decky-loader/releases/download/v1/PluginLoader"}]}]' > "$2"
        fi
    }
    find_release release "$TEST_DIR"
    [ "$VERSION" = v1 ]
}

@test "ARM64 ELF succeeds while HTML masquerading as an asset fails" {
    make_elf "$TEST_DIR/binary"
    printf '\267\000' | dd of="$TEST_DIR/binary" bs=1 seek=18 conv=notrunc status=none
    run validate_binary "$TEST_DIR/binary" 64 none arm64
    [ "$status" -eq 0 ]
    printf '<html>error</html>' > "$TEST_DIR/binary"
    run validate_binary "$TEST_DIR/binary" 18 none x86_64
    [ "$status" -eq 5 ]
}

@test "symlinked home paths and root targets are rejected" {
    getent() { printf 'tester:x:1000:1000::%s:/bin/bash\n' "$TEST_DIR/link"; }
    ln -s "$TARGET_HOME" "$TEST_DIR/link"
    run resolve_user tester
    [ "$status" -eq 3 ]; [[ $output == *symlink* ]]
    getent() { printf 'root:x:0:0::/root:/bin/bash\n'; }
    run resolve_user root
    [ "$status" -eq 3 ]; [[ $output == *non-root* ]]
}

@test "parallel deployment cannot acquire an already held lock" {
    exec 9>"$TEST_DIR/lock"
    flock -n 9
    run bash -c 'exec 9>&-; exec 8>"$1"; flock -n 8' _ "$TEST_DIR/lock"
    [ "$status" -eq 1 ]
    exec 9>&-
}

@test "without a terminal the updater requires an explicit selection" {
    run setsid bash "$ROOT/cli/dist/decky-updater.sh"
    [ "$status" -eq 2 ]; [[ $output == *'No terminal'* ]]
}

@test "menu reads its controlling terminal even with stdin redirected" {
    run python3 - "$ROOT" <<'PY'
import os, pty, select, sys, time
root = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execlp('bash', 'bash', '-c', 'source "$1/cli/src/common.sh"; source "$1/cli/src/main.sh"; DEFAULT_OPERATION=choose; parse_args < /dev/null; echo "CHOSEN=$OPERATION"', '_', root)
data = b''
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if select.select([fd], [], [], 0.1)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        data += chunk
        if b'(s/p/u): ' in data and b'CHOSEN=' not in data:
            os.write(fd, b'p\n')
        if b'CHOSEN=prerelease' in data:
            break
else:
    os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
print(data.decode())
assert os.waitstatus_to_exitcode(status) == 0
assert b'CHOSEN=prerelease' in data
PY
    [ "$status" -eq 0 ]
}

@test "legacy service with an unavailable user manager fails before deployment" {
    mkdir -p "$TARGET_HOME/.config/systemd/user"
    touch "$TARGET_HOME/.config/systemd/user/plugin_loader.service"
    worker_ctl() { return 0; }
    worker_user_ctl() { return 1; }
    run worker_service_state
    [ "$status" -eq 3 ]; [[ $output == *'user systemd manager is unavailable'* ]]
}

@test "literal dollar characters survive generated ExecStart expansion" {
    TARGET_HOME='/home/a$USER'; W_OPERATION=release
    run worker_unit
    [[ $output == *'ExecStart="/home/a$$USER/homebrew/services/PluginLoader"'* ]]
    [[ $output == *'WorkingDirectory=/home/a$USER/homebrew/services'* ]]
}

@test "missing Steam data fails before downloading or deploying" {
    resolve_user() { TARGET_UID=$EUID; }
    network_get() { touch "$TEST_DIR/unexpected-network"; }
    run prepare release tester "$TEST_DIR/work"
    [ "$status" -eq 3 ]; [[ $output == *'Start Steam once'* ]]
    [ ! -e "$TEST_DIR/unexpected-network" ]
}

@test "download failure leaves the installed binary and Steam markers unchanged" {
    resolve_user() { TARGET_UID=$EUID; }
    mkdir -p "$TARGET_HOME/.steam/steam" "$TARGET_HOME/homebrew/services"
    printf old > "$TARGET_HOME/homebrew/services/PluginLoader"
    network_get() { fail 4 'Injected network failure'; }
    run prepare release tester "$TEST_DIR/work"
    [ "$status" -eq 4 ]
    [ "$(cat "$TARGET_HOME/homebrew/services/PluginLoader")" = old ]
    [ ! -e "$TARGET_HOME/.steam/steam/.cef-enable-remote-debugging" ]
}
