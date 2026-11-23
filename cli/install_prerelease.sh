#!/usr/bin/env bash

# SHARED INSTALLER FILE FOR CLI INSTALLS OF DECKY, install.sh, install_release.sh, install_prerelease.sh MUST HAVE IDENTICAL CONTENTS

FILENAME=$(basename "$0")
RELARG="$1"
DLPRE=false

if [[ $FILENAME =~ "prerelease" ]]; then
    DLPRE=true
elif [[ $RELARG =~ "pre" ]]; then
    DLPRE=true
fi

[ "$UID" -eq 0 ] || exec sudo "$0" "$@"

# check if JQ is installed
if ! command -v jq &> /dev/null
then
    echo "JQ could not be found, please install it"
    echo "Info on how to install it can be found at https://stedolan.github.io/jq/download/"
    exit 1
fi

# check if github.com is reachable
if ! curl -Is https://github.com | head -1 | grep 200 > /dev/null
then
    echo "Github appears to be unreachable, you may not be connected to the internet"
    exit 1
fi

# check if api.github.com is working(not rate-limited)
if ! curl -Is https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases | head -1 | grep 200 > /dev/null
then
    echo "Your network have problems accessing Github Api(probably rate-limited), please wait for a while and try again."
    exit 1
fi

if $DLPRE; then
    echo "Installing Decky Loader pre-release..."
else
    echo "Installing Decky Loader stable release..."
fi

USER_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
HOMEBREW_FOLDER="${USER_DIR}/homebrew"

# Create folder structure
sudo -u "$SUDO_USER" mkdir -p "${HOMEBREW_FOLDER}/plugins"
sudo -u "$SUDO_USER" touch "${USER_DIR}/.steam/steam/.cef-enable-remote-debugging"
# if installed as flatpak, put .cef-enable-remote-debugging there
[ -d "${USER_DIR}/.var/app/com.valvesoftware.Steam/data/Steam/" ] && sudo -u "$SUDO_USER" touch "${USER_DIR}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"

# Release assets are per CPU architecture; the installed binary is always PluginLoader
case "$(uname -m)" in
    aarch64|arm64) ASSET="PluginLoader-arm64" ;;
    *) ASSET="PluginLoader" ;;
esac

RELEASE_DATA=$(curl -s 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases')
PRE=$(jq -r "first(.[] | select(.prerelease == "true"))" <<< "${RELEASE_DATA}")
REL=$(jq -r "first(.[] | select(.prerelease == "false"))" <<< "${RELEASE_DATA}")

# Check what the file is being invoked by runner, then match expected behavior to support references to obsolete files
if $DLPRE; then
    # Check if pre-release is older version than latest stable release
    PREVER=$(jq -r '.tag_name' <<< "${PRE}" )
    RELVER=$(jq -r '.tag_name' <<< "${REL}" )

    PREVERS=${PREVER%-*}
    RELVERS=${RELVER%-*}

    SORTVER=$(printf '%s\n' "$PREVERS" "$RELVERS" | sort -V -r | head -n1)

    if [[ $SORTVER == "$RELVERS" ]]; then
        RELEASE=$REL
        VERSION=$RELVER
    elif [[ $SORTVER == "$PREVERS" ]]; then
        RELEASE=$PRE
        VERSION=$PREVER
    else
        ## Fallback to release version if we somehow get here
        RELEASE=$REL
        VERSION=$RELVER
    fi
else
    RELEASE=$REL
    VERSION=$(jq -r '.tag_name' <<< "${RELEASE}")
fi

# Download most up-to-date release and install it
DOWNLOADURL=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .browser_download_url' <<< "${RELEASE}")
DOWNLOADSIZE=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .size' <<< "${RELEASE}")
DOWNLOADHASH=$(jq -r --arg asset "$ASSET" '.assets[] | select(.name == $asset) | .digest' <<< "${RELEASE}")
# Only replace the existing install once there is something to download
if [ -z "$DOWNLOADURL" ]; then
    echo "No Decky Loader pre-release with a $ASSET build was found, or GitHub could not be reached."
    exit 1
fi

printf "Downloading version %s...\n" "${VERSION}"

# Download binary before removing any files
curl -L "$DOWNLOADURL" --output ${HOMEBREW_FOLDER}/PluginLoader.tmp

# Check binary size
FILESIZE=$(du -b "$HOMEBREW_FOLDER"/PluginLoader.tmp | cut -f1)
if [[ ! -s $HOMEBREW_FOLDER/PluginLoader.tmp ]]; then
    printf "Failed to download version %s...\n" "${VERSION}"
    printf "Downloaded binary is zero bytes."
    exit 1
elif [[ $FILESIZE != "$DOWNLOADSIZE"  ]]; then
    printf "Failed to download version %s...\n" "${VERSION}"
    printf "Downloaded binary is smaller than expected size."
    exit 1
fi

# Check binary hash TODO, implement hash files included with releases
FILEHASH=$(sha256sum ${HOMEBREW_FOLDER}/PluginLoader.tmp | sed 's, .*,,')
if [[ $FILEHASH != ${DOWNLOADHASH#*:} ]]; then
    printf "Failed to download version %s...\n" "${VERSION}"
    printf "Downloaded binary's hash is mismatched."
    exit 1
fi

# Stop services before deleting folder

systemctl --user stop plugin_loader 2> /dev/null
systemctl --user disable plugin_loader 2> /dev/null

systemctl stop plugin_loader 2> /dev/null
systemctl disable plugin_loader 2> /dev/null

# Delete old folder and contents, make new folder owned by sudo
rm -rf "${HOMEBREW_FOLDER}/services"
sudo -u "$SUDO_USER" mkdir -p "${HOMEBREW_FOLDER}/services"

printf "Installing version %s...\n" "${VERSION}"

# Move and mark binary as executable
mv "${HOMEBREW_FOLDER}"/PluginLoader.tmp "${HOMEBREW_FOLDER}"/services/PluginLoader
chmod +x "${HOMEBREW_FOLDER}"/services/PluginLoader

echo "$VERSION" > "${HOMEBREW_FOLDER}"/services/.loader.version

# SELinux checks/fixes
echo "Check for SELinux presence and if it is present, set the correct permission on the binary file..."
hash getenforce 2>/dev/null && getenforce | grep "Enforcing" >/dev/null && chcon -t bin_t "${HOMEBREW_FOLDER}"/services/PluginLoader

if $DLPRE; then
    curl -L https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-prerelease.service  --output "${HOMEBREW_FOLDER}"/services/plugin_loader-prerelease.service
else
    curl -L https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-release.service  --output "${HOMEBREW_FOLDER}"/services/plugin_loader-release.service
fi

cat > "${HOMEBREW_FOLDER}/services/plugin_loader-backup.service" <<- EOM
[Unit]
Description=SteamDeck Plugin Loader
After=network.target
[Service]
Type=simple
User=root
Restart=always
KillMode=process
TimeoutStopSec=15
ExecStart=${HOMEBREW_FOLDER}/services/PluginLoader
WorkingDirectory=${HOMEBREW_FOLDER}/services
Environment=UNPRIVILEGED_PATH=${HOMEBREW_FOLDER}
Environment=PRIVILEGED_PATH=${HOMEBREW_FOLDER}
Environment=LOG_LEVEL=DEBUG
[Install]
WantedBy=multi-user.target
EOM

if $DLPRE; then
    if [[ -f "${HOMEBREW_FOLDER}/services/plugin_loader-prerelease.service" ]]; then
        printf "Grabbed latest prerelease service.\n"
        sed -i -e "s|\${HOMEBREW_FOLDER}|${HOMEBREW_FOLDER}|" "${HOMEBREW_FOLDER}/services/plugin_loader-prerelease.service"
        cp -f "${HOMEBREW_FOLDER}/services/plugin_loader-prerelease.service" "/etc/systemd/system/plugin_loader.service"
    else
        printf "Could not curl latest prerelease systemd service, using built-in service as a backup!\n"
        rm -f "/etc/systemd/system/plugin_loader.service"
        cp "${HOMEBREW_FOLDER}/services/plugin_loader-backup.service" "/etc/systemd/system/plugin_loader.service"
    fi
else
    if [[ -f "${HOMEBREW_FOLDER}/services/plugin_loader-release.service" ]]; then
        printf "Grabbed latest release service.\n"
        sed -i -e "s|\${HOMEBREW_FOLDER}|${HOMEBREW_FOLDER}|" "${HOMEBREW_FOLDER}/services/plugin_loader-release.service"
        cp -f "${HOMEBREW_FOLDER}/services/plugin_loader-release.service" "/etc/systemd/system/plugin_loader.service"
    else
        printf "Could not curl latest release systemd service, using built-in service as a backup!\n"
        rm -f "/etc/systemd/system/plugin_loader.service"
        cp "${HOMEBREW_FOLDER}/services/plugin_loader-backup.service" "/etc/systemd/system/plugin_loader.service"
    fi
fi

mkdir -p "${HOMEBREW_FOLDER}"/services/.systemd

if $DLPRE; then
    cp "${HOMEBREW_FOLDER}"/services/plugin_loader-prerelease.service "${HOMEBREW_FOLDER}"/services/.systemd/plugin_loader-prerelease.service
    cp "${HOMEBREW_FOLDER}"/services/plugin_loader-backup.service "${HOMEBREW_FOLDER}"/services/.systemd/plugin_loader-backup.service
    rm "${HOMEBREW_FOLDER}"/services/plugin_loader-backup.service "${HOMEBREW_FOLDER}"/services/plugin_loader-prerelease.service
else
    cp "${HOMEBREW_FOLDER}"/services/plugin_loader-release.service "${HOMEBREW_FOLDER}"/services/.systemd/plugin_loader-release.service
    cp "${HOMEBREW_FOLDER}"/services/plugin_loader-backup.service "${HOMEBREW_FOLDER}"/services/.systemd/plugin_loader-backup.service
    rm "${HOMEBREW_FOLDER}"/services/plugin_loader-backup.service "${HOMEBREW_FOLDER}"/services/plugin_loader-release.service
fi

systemctl daemon-reload
systemctl start plugin_loader
systemctl enable plugin_loader

# this (retroactively) fixes a bug where users who ran the installer would have homebrew owned by root instead of their user
if [ "$SUDO_USER" =  "deck" ]; then
  sudo chown -R deck:deck "${HOMEBREW_FOLDER}"
  sudo chown -R root:root "${HOMEBREW_FOLDER}"/services/*
fi