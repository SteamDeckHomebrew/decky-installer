#!/bin/bash

# if a password was set by decky, this will run when the program closes
temp_pass_cleanup() {
  echo $PASS | sudo -S -k passwd -d deck
}

# removes unhelpful GTK warnings
zen_nospam() {
  zenity 2> >(grep -v 'Gtk' >&2) "$@"
}

# check if JQ is installed
if ! command -v jq &> /dev/null
then
    echo "JQ could not be found, please install it"
    echo "Info on how to install it can be found at https://stedolan.github.io/jq/download/"
    exit
fi

# check if github.com is reachable
if ! curl -Is https://github.com | head -1 | grep 200 > /dev/null
then
    echo "Github appears to be unreachable, you may not be connected to the internet"
    exit 1
fi

# if the script is not root yet, get the password and rerun as root
if (( $EUID != 0 )); then
    PASS_STATUS=$(passwd -S deck 2> /dev/null)
    if [ "$PASS_STATUS" = "" ]; then
        echo "Deck user not found. Continuing anyway, as it probably just means user is on a non-steamos system."
    fi

    if [ "${PASS_STATUS:5:2}" = "NP" ]; then # if no password is set
        if ( zen_nospam --title="Decky Installer" --width=300 --height=200 --question --text="You appear to have not set an admin password.\nDecky can still install by temporarily setting your password to 'Decky!' and continuing, then removing it when the installer finishes\nAre you okay with that?" ); then
            yes "Decky!" | passwd deck # set password to Decky!
            trap temp_pass_cleanup EXIT # make sure that password is removed when application closes
            PASS="Decky!"
        else exit 1; fi
    else
        # get password
        FINISHED="false"
        while [ "$FINISHED" != "true" ]; do
            PASS=$(zen_nospam --title="Decky Installer" --width=300 --height=100 --entry --hide-text --text="Enter your sudo/admin password")
            if [[ $? -eq 1 ]] || [[ $? -eq 5 ]]; then
                exit 1
            fi
            if ( echo "$PASS" | sudo -S -k true ); then
                FINISHED="true"
            else
                zen_nospam --title="Decky Installer" --width=150 --height=40 --info --text "Incorrect Password"
            fi
        done
    fi

    if ! [ $USER = "deck" ]; then
        zen_nospam --title="Decky Installer" --width=300 --height=100 --warning --text "You appear to not be on a deck.\nDecky should still mostly work, but you may not get full functionality."
    fi
    
    echo "$PASS" | sudo -S -k bash "$0" "$@" # rerun script as root
    exit 1
fi

# all code below should be run as root
USER_DIR="$(getent passwd $SUDO_USER | cut -d: -f6)"
HOMEBREW_FOLDER="${USER_DIR}/homebrew"

# if decky is already installed, then add 'uninstall' and 'wipe' option
if [[ -f "${USER_DIR}/homebrew/services/PluginLoader" ]] ; then
    OPTION=$(zen_nospam --title="Decky Installer" --width=420 --height=200 --list --radiolist --text "Select Option:" --hide-header --column "Buttons" --column "Choice" --column "Info" \
    TRUE "update to latest release" "Recommended option" \
    FALSE "update to latest prerelease" "May be unstable" \
    FALSE "uninstall decky loader" "Will keep config intact" \
    FALSE "wipe decky loader" "Will NOT keep config intact")
else
    OPTION=$(zen_nospam --title="Decky Installer" --width=300 --height=100 --list --radiolist --text "Select branch to install:" --hide-header --column "Buttons" --column "Choice" --column "Info" \
    TRUE "release" "(Recommended option)" \
    FALSE "prerelease" "(May be unstable)")
fi

if [[ $? -eq 1 ]] || [[ $? -eq 5 ]]; then
    exit 1
fi

# uninstall if uninstall option was selected
if [[ "$OPTION" == "uninstall decky loader" || "$OPTION" == "wipe decky loader" ]] ; then
    (
    echo "20" ; echo "# Disabling and removing services" ;
    sudo systemctl disable --now plugin_loader.service > /dev/null
    sudo rm -f "${USER_DIR}/.config/systemd/user/plugin_loader.service"
    sudo rm -f "/etc/systemd/system/plugin_loader.service"

    echo "40" ; echo "# Removing Temporary Files" ;
    rm -rf "/tmp/plugin_loader"
    rm -rf "/tmp/user_install_script.sh"

    if [ "$OPTION" == "wipe decky loader" ]; then
        echo "60" ; echo "# Deleting homebrew folder" ;
        sudo rm -r "${HOMEBREW_FOLDER}"
    else
        echo "60" ; echo "# Cleaning services folder" ;
        sudo rm "${HOMEBREW_FOLDER}/services/PluginLoader"
    fi

    echo "80" ; echo "# Disabling CEF debugging" ;
    sudo rm "${USER_DIR}/.steam/steam/.cef-enable-remote-debugging"

    echo "100" ; echo "# Uninstall finished, installer can now be closed";
    ) |
    zen_nospam --progress \
  --title="Decky Installer" \
  --width=300 --height=100 \
  --text="Uninstalling..." \
  --percentage=0 \
  --no-cancel
  exit 1
fi

# otherwise, install decky
if [[ "$OPTION" =~ "pre" ]]; then
    BRANCH="prerelease"
else
    BRANCH="release"
fi

(
echo "15" ; echo "# Creating file structure" ;
rm -rf "${HOMEBREW_FOLDER}/services"
sudo -u $SUDO_USER  mkdir -p "${HOMEBREW_FOLDER}/services"
sudo -u $SUDO_USER  mkdir -p "${HOMEBREW_FOLDER}/plugins"
sudo -u $SUDO_USER  touch "${USER_DIR}/.steam/steam/.cef-enable-remote-debugging"

echo "30" ; echo "# Finding latest $BRANCH";
if [ "$BRANCH" = 'prerelease' ] ; then
    RELEASE=$(curl -s 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases' | jq -r "first(.[] | select(.prerelease == "true"))")
else
    RELEASE=$(curl -s 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases' | jq -r "first(.[] | select(.prerelease == "false"))")
fi
VERSION=$(jq -r '.tag_name' <<< ${RELEASE} )
DOWNLOADURL=$(jq -r '.assets[].browser_download_url | select(endswith("PluginLoader"))' <<< ${RELEASE})

echo "45" ; echo "# Installing version $VERSION" ;
# make another zenity prompt while downloading the PluginLoader file, I do not know how this works
curl -L $DOWNLOADURL -o ${HOMEBREW_FOLDER}/services/PluginLoader 2>&1 | stdbuf -oL tr '\r' '\n' | sed -u 's/^ *\([0-9][0-9]*\).*\( [0-9].*$\)/\1\n#Download Speed\:\2/' | zen_nospam --progress --title "Downloading Decky" --text="Download Speed: 0" --width=300 --height=100 --auto-close --no-cancel
chmod +x ${HOMEBREW_FOLDER}/services/PluginLoader

echo "60"; echo "Running SELinux fix if it is enabled"
hash getenforce 2>/dev/null && getenforce | grep "Enforcing" >/dev/null && chcon -t bin_t ${HOMEBREW_FOLDER}/services/PluginLoader

echo $VERSION > ${HOMEBREW_FOLDER}/services/.loader.version

echo "70" ; echo "# Kiling plugin_loader if it exists" ;
systemctl --user stop plugin_loader 2> /dev/null
systemctl --user disable plugin_loader 2> /dev/null
systemctl stop plugin_loader 2> /dev/null
systemctl disable plugin_loader 2> /dev/null

echo "85" ; echo "# Setting up systemd" ;
curl -L https://raw.githubusercontent.com/SteamDeckHomebrew/decky-loader/main/dist/plugin_loader-${BRANCH}.service  --output ${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service
cat > "${HOMEBREW_FOLDER}/services/plugin_loader-backup.service" <<- EOM
[Unit]
Description=SteamDeck Plugin Loader
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Restart=always
ExecStart=${HOMEBREW_FOLDER}/services/PluginLoader
WorkingDirectory=${HOMEBREW_FOLDER}/services
KillSignal=SIGKILL
Environment=PLUGIN_PATH=${HOMEBREW_FOLDER}/plugins
Environment=LOG_LEVEL=INFO
[Install]
WantedBy=multi-user.target
EOM

# if .service file doesn't exist for whatever reason, use backup file instead
if [[ -f "${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service" ]]; then
    printf "Grabbed latest ${BRANCH} service.\n"
    sed -i -e "s|\${HOMEBREW_FOLDER}|${HOMEBREW_FOLDER}|" "${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service"
    cp -f "${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service" "/etc/systemd/system/plugin_loader.service"
else
    printf "Could not curl latest ${BRANCH} systemd service, using built-in service as a backup!\n"
    rm -f "/etc/systemd/system/plugin_loader.service"
    cp "${HOMEBREW_FOLDER}/services/plugin_loader-backup.service" "/etc/systemd/system/plugin_loader.service"
fi

mkdir -p ${HOMEBREW_FOLDER}/services/.systemd
cp ${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service ${HOMEBREW_FOLDER}/services/.systemd/plugin_loader-${BRANCH}.service
cp ${HOMEBREW_FOLDER}/services/plugin_loader-backup.service ${HOMEBREW_FOLDER}/services/.systemd/plugin_loader-backup.service
rm ${HOMEBREW_FOLDER}/services/plugin_loader-backup.service ${HOMEBREW_FOLDER}/services/plugin_loader-${BRANCH}.service

systemctl daemon-reload
systemctl start plugin_loader
systemctl enable plugin_loader

# this (retroactively) fixes a bug where users who ran the installer would have homebrew owned by root instead of their user
# will likely be removed at some point in the future
if [ "$SUDO_USER" =  "deck" ]; then
  sudo chown -R deck:deck "${HOMEBREW_FOLDER}"
  sudo chown -R root:root "${HOMEBREW_FOLDER}"/services/*
fi

echo "100" ; echo "# Install finished, installer can now be closed";
) |
zen_nospam --progress \
  --title="Decky Installer" \
  --width=300 --height=100 \
  --text="Installing..." \
  --percentage=0 \
  --no-cancel # not actually sure how to make the cancel work properly, so it's just not there unless someone else can figure it out

if [ "$?" = -1 ] ; then
        zen_nospam --title="Decky Installer" --width=150 --height=70 --error --text="Download interrupted."
fi
