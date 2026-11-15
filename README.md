# decky-installer <img src="https://img.shields.io/github/downloads/SteamDeckHomebrew/decky-installer/total"/>
Installer for <a href="https://github.com/SteamDeckHomebrew/decky-loader">decky loader</a>

## Command-line installation

The release assets are standalone Bash scripts. No checkout or additional script
downloads are required:

```bash
curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | bash
```

For better reporting of the **outer** download's HTTP failures, use `curl -fsSL`
instead of `curl -L`. Bash parses the complete script before installation starts;
a truncated script does not start a partial installation. The installer cannot
control the outer curl process. To retain both processes' failure status in Bash,
enable `set -o pipefail` before running the pipeline.

Available assets:

| Script | Action |
| --- | --- |
| `install_release.sh` | Install/update to the latest stable release |
| `install_prerelease.sh` | Install/update to the latest prerelease |
| `uninstall.sh` | Remove Loader and its service; retain plugins and settings |
| `decky-updater.sh` | Choose an action interactively, or pass `s`, `p`, or `u` |

Switch channels by running the other installation script. Installation always
redeploys the selected channel's latest version, including on repeat runs.
Uninstall is repeatable; it retains unrelated service files and version records.

```bash
# Supply updater arguments after `bash -s --` when reading the script from stdin.
curl -fsSL https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/decky-updater.sh | bash -s -- p

# Saved scripts work too.
bash install_release.sh --help
sudo bash install_release.sh --user deck
```

Every entry accepts `--help` and `--user USER`. Normally the target is the invoking
user; when invoked with sudo it is `SUDO_USER`. Direct root execution requires
`--user`. A non-root process cannot select a different target user. The target
must have an existing, non-symlinked home directory.

## Requirements and permissions

Requires Linux with a running systemd manager, Bash 4+, sudo, curl, jq, GNU
coreutils, getent, awk and flock (util-linux). Supports x86_64 and ARM64. SELinux
enforcing systems also need `chcon`. Dependencies are checked, not installed.

Metadata fetching, downloads, verification and user-directory preparation run as
the target user, including when the entrypoint starts as root. Only the isolated
deployment worker manages protected service files, executable ownership, SELinux
labels and systemd. It performs no network requests. Steam debugging markers
are created or removed as the target user while the deployment lock is held.
Steam must have been started once so its native or Flatpak data directory exists.

sudo may prompt on the controlling terminal. Without a terminal, supply an
explicit updater selection and have noninteractive sudo authorization available;
the installer never reads passwords or menu answers from the script's stdin.

Loader retains its existing root system service and `~/homebrew/services` layout
for compatibility. This is **not a sandbox for Loader or plugins**: the target
user still controls the parent home directory. Installation rejects symlinked
deployment targets, but does not establish a security boundary against a malicious
target user concurrently modifying their own home. System administrators should
treat that user and their plugins as trusted before authorizing installation.

## Downloads and recovery

HTTPS certificate verification remains enabled. Standard curl proxy environment
variables are supported, including for root-invoked preparation. `.curlrc` is
ignored so it cannot silently override the installer's network policy. No mirror
or certificate-verification bypass is selected automatically.

Requests have a 15-second connection timeout, a 60-second metadata deadline and
a 10-minute binary deadline. Transient failures get at most two retries. Numeric
`Retry-After` values up to 30 seconds are honored; longer or date-form delays are
reported for the user to retry later. GitHub API rate-limit exhaustion reports
the reset Unix timestamp when available.

Downloads must match the asset size and ELF architecture. A supplied SHA-256
digest is verified; if GitHub provides none, that limitation is reported. No
independent signature verification is claimed. Systemd templates ship inside
the installer rather than being fetched from the upstream main branch.

The previous installation stays running during downloads and validation. During
deployment, the old services directory and unit are retained for rollback. A new
service must stay active without automatic restarts for five seconds; this tests
process startup, not Steam UI or plugin functionality. Deployment failures restore
the previous files and active/enabled state. Failed rollback retains a
`~/homebrew/.decky-backup.*` directory and prints its path; preserve it, inspect
`journalctl -u plugin_loader.service`, and restore its `services` and `unit` files
with the service stopped. Successful deployment removes the backup.

Catchable interruption triggers cleanup/rollback. SIGKILL, power loss and storage
failure cannot guarantee rollback; retained backup directories may require manual
recovery. An unavailable legacy user service manager causes installation to stop
before replacement: log in as that user and retry. Masked or otherwise unsupported
service enablement states must be resolved before installation.

| Exit code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Invalid arguments or missing noninteractive selection |
| 3 | Missing dependencies, incompatible environment or permissions |
| 4 | Network/HTTP failure |
| 5 | Invalid release metadata or binary verification failure |
| 6 | Deployment/service failure; rollback attempted where needed |
| 7 | Rollback/cleanup of installation state failed; inspect recovery instructions |
| 129 / 130 / 143 | HUP / interrupt / termination, unless rollback itself failed |

## Development and validation

`cli/src` contains function-only modules: common validation, network/release
selection, privileged deployment and CLI orchestration. `cli/build.sh` assembles
four standalone scripts in ignored `cli/dist`; edit the modules, not generated
files. The outer compound command makes stdin delivery work without re-executing
`$0`. The deployment subprocess receives only explicitly serialized worker
functions and validated arguments; there is no `eval` or dynamically sourced
remote module.

```bash
bash cli/build.sh
# Requires ShellCheck, Bats, jq and Python 3 in addition to runtime dependencies.
bash cli/test.sh
```

Behavior tests replace network and service operations and use temporary files;
they do not install Decky or change host services. CI also uses a disposable
systemd container to exercise real install, update, channel switching, startup
failure rollback, direct-root execution and repeated uninstall:

```bash
docker build -f cli/tests/Containerfile -t decky-cli-test .
docker run -d --name decky-cli-test --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock decky-cli-test
docker exec decky-cli-test bash /workspace/cli/tests/systemd.sh
docker rm -f decky-cli-test
```

The container test uses a tiny synthetic executable and deterministic GitHub
responses; it does not test upstream Decky functionality. ARM64 resource and ELF
selection are covered by behavior tests; an ARM64 device is still required for
end-to-end runtime validation. The GUI installer is unchanged. Releases run the
CLI checks, build the four scripts, and upload `cli/dist/*.sh` alongside GUI assets
to the existing draft Release workflow.

On rootless container storage mounted `nosuid`, pass
`-e DECKY_TEST_ROOT_ENTRY=1` to `docker exec` (or `podman exec`) to test the
root `--user` entrypoint instead. This still exercises unprivileged preparation
and real systemd operations, but does not validate non-root sudo elevation.
