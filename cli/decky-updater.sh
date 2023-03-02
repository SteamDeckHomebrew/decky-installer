#!/bin/sh

#If $1 is set, take that as input
[ -n "$1" ] && release="$1"

#Keep asking which release to install
while true
do
    #If $release is set by $1, take that as input
    [ -z "$release" ] && read -p "Install stable/pre-release or uninstall (s/p/u): " release

    #Only accept answers with S for stable or P for pre-release
    case $(echo "${release}" | tr '[:lower:]' '[:upper:]') in
    S*)
        echo "Installing stable version"
        curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh
        exit 0
        ;;
    P*)
        echo "Installing pre-release"
        curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_prerelease.sh | sh
        exit 0
        ;;
    U*)
        echo "Uninstalling decky"
        curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/uninstall.sh | sh
        exit 0
        ;;
    *)
        unset release
        continue
        ;;
    esac
done
