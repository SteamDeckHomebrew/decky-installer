#!/usr/bin/env bash
# Run only inside the disposable systemd container built from tests/Containerfile.
set -euo pipefail
[[ -f /etc/decky-cli-test-container && $EUID == 0 ]] || { echo 'An isolated test container is required.' >&2; exit 1; }
timeout 60s systemctl is-system-running --wait || [[ $(systemctl is-system-running) == degraded ]]
mkdir -p /fixtures
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' | gcc -x c - -o /fixtures/good
printf 'int main(void) { return 1; }\n' | gcc -x c - -o /fixtures/bad
cp /fixtures/good /fixtures/asset
# A deterministic transport fixture; no production network is contacted.
cat > /usr/local/bin/curl <<'CURL'
#!/bin/bash
set -eu
while (( $# )); do
    case $1 in
        --output) output=$2; shift ;;
        --dump-header) headers=$2; shift ;;
        https://*) url=$1 ;;
    esac
    shift
done
printf 'HTTP/1.1 200 OK\r\n' > "$headers"
if [[ $url == *api.github.com* ]]; then
    size=$(stat -c %s /fixtures/asset)
    digest=$(sha256sum /fixtures/asset); digest=${digest%% *}
    jq -n --argjson size "$size" --arg digest "sha256:$digest" \
        '[false,true] | map({draft:false,prerelease:.,tag_name:(if . then "v2-pre" else "v1" end),assets:[{name:"PluginLoader",size:$size,digest:$digest,browser_download_url:"https://github.com/SteamDeckHomebrew/decky-loader/releases/download/v1/PluginLoader"}]})' > "$output"
else cp /fixtures/asset "$output"; fi
printf 200
CURL
chmod +x /usr/local/bin/curl
run_user() { sudo -u deckytest bash -c "$1"; }
run_installer() {
    local script=$1 args=${2:-}
    if [[ ${DECKY_TEST_ROOT_ENTRY:-0} == 1 ]]; then
        # Useful for rootless test storage mounted nosuid: sudo cannot elevate a
        # non-root caller there. Preparation must still drop to deckytest.
        if [[ -n $args ]]; then
            env -u SUDO_USER bash "/workspace/cli/dist/$script.sh" --user deckytest "$args"
        else env -u SUDO_USER bash "/workspace/cli/dist/$script.sh" --user deckytest; fi
    else
        run_user "cat /workspace/cli/dist/$script.sh | bash -s -- $args"
    fi
}
# Expanded by the target user's shell.
# shellcheck disable=SC2016
run_user 'mkdir -p "$HOME/.steam/steam"'
run_installer install_release
systemctl is-active --quiet plugin_loader
systemctl is-enabled --quiet plugin_loader
# shellcheck disable=SC2016
run_user 'printf keep > "$HOME/homebrew/plugins/data"'
# Exercise a repeat install and a channel switch.
run_installer install_release
run_installer decky-updater p
[[ $(cat '/home/decky test/homebrew/services/.loader.version') == v2-pre ]]
# A valid ELF which immediately exits must fail and restore the working version.
cp /fixtures/bad /fixtures/asset
set +e
run_installer install_release
result=$?
set -e
[[ $result == 6 ]]
systemctl is-active --quiet plugin_loader
cmp /fixtures/good '/home/decky test/homebrew/services/PluginLoader'
[[ $(cat '/home/decky test/homebrew/services/.loader.version') == v2-pre ]]
# Direct-root operation requires an explicit target and prepares as that user.
cp /fixtures/good /fixtures/asset
env -u SUDO_USER bash /workspace/cli/dist/install_release.sh --user deckytest
run_installer uninstall
run_installer uninstall
[[ ! -e '/home/decky test/homebrew/services/PluginLoader' ]]
[[ ! -e '/home/decky test/.steam/steam/.cef-enable-remote-debugging' ]]
[[ $(cat '/home/decky test/homebrew/plugins/data') == keep ]]
printf 'Real systemd lifecycle checks passed.\n'
