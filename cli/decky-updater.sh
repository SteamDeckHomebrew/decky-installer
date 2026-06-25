#!/bin/sh

URL_BASE="https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download"

#If $1 is set, take that as input
[ -n "$1" ] && release="$1"

#Keep asking which release to install
while true
do
    #If $release is set by $1, take that as input
    if [ -z "$release" ]; then
        read -p "Install stable[S]/pre-release[P] or uninstall[U]: " release
    fi

    #Only accept answers with S for stable or P for pre-release
    case "${release^^}" in
    S*)
        echo "Installing stable version"
        curl -L "${URL_BASE}/install_release.sh" |bash
        exit 0
        ;;
    P*)
        echo "Installing pre-release"
        curl -L "${URL_BASE}/install_prerelease.sh" | bash
        exit 0
        ;;
    U*)
        echo "Uninstalling decky"
        curl -L "${URL_BASE}/uninstall.sh" | bash
        exit 0
        ;;
    *)
        echo "Invalid option '$release'. Please use S (stable), P (pre-release), or U (uninstall)."
        unset release
        continue
        ;;
    esac
done
