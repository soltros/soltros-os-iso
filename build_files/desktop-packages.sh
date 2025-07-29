#!/usr/bin/bash

[[ -n "${SET_X:-}" ]] && set -x
set -euo pipefail

trap '[[ $BASH_COMMAND != echo* ]] && [[ $BASH_COMMAND != log* ]] && echo "+ $BASH_COMMAND"' DEBUG

log() {
  echo "=== $* ==="
}

log "Installing RPM packages"

# Layered Applications
LAYERED_PACKAGES=(
    # Core system
    zsh
    nmcli
    usbutils
    pciutils
    buildah
    skopeo
    wireguard-tools
    exfatprogs
    ntfs-3g
    btrfs-progs
    squashfs-tools
    genisoimage
    syslinux
    spice-webdav
)

dnf5 install --setopt=install_weak_deps=False --nogpgcheck --skip-unavailable -y "${LAYERED_PACKAGES[@]}"

dnf5 remove plymouth -y

log "Package install complete."

