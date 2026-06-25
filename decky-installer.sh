#!/usr/bin/env bash
# vim: set ft=bash ts=2 sw=2 sts=2 expandtab :
VERSION=1.0.0

set -u

main() {
  help
  preflight_checks
  handle_root_password
  select_branch
  # case:
  # install
  # uninstall
  # doctor
  # revert to previous version
  # force clean
  # export homebrew config as tar
}

help(){
  printf "█▓▒░ Decky Installer Suite\n"
  exit 0
}

preflight_checks(){
  . /etc/os-release
  OS_NAME="${NAME:-unknown}"
  CURRENT_USER=$(whoami)
  # if script is called from gui
  # jq available
  # zenity availability
  # check if root privelegies are available
  # github is available
  # mktemp
  # check if systemd is active
  # check if deckyloader is already installed and it's version
}
select_action(){
  :
  # install release
  # install prerelease
  # uninstall
  # doctor
}
install(){
  :
  mkdir -p ~/homebrew/services/ ~/homebrew/plugins/
  # enable CEF devtools
  # test -d  ${HOME}/.steam/steam/ && touch ~/.steam/steam/.cef-enable-remote-debugging
  # test -d ${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/ && touch ${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging
  # download systemd service
  # download PluginLoader
  # echo version > tmpdir/.loader.version
  # stop plugin_loader.service if exists on user and system level
  # back up old variants if exist
  # force chown
  # install systemd service

  systemctl daemon-reload
  systemctl start plugin_loader
  systemctl enable plugin_loader

}

main $@

# Do not forget:
# - Flags management
# - Trap error
# - Revert changes
