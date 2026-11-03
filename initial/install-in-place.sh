#!/usr/bin/env bash
# Install NixOS in place of the Debian system of the Android 17 Terminal app.
#
# Run it inside the Terminal, as root:
#   sudo bash install-in-place.sh
#
# The Android 17 Terminal boots its bundled kernel and initrd directly (no EFI partition)
# and checks build_id, cidata.build_id and vm_config.json in its app data on every start.
# The guest can't write those any more (/mnt/internal is gone), and an image the Terminal
# didn't install itself gets the "Upgrade to newer terminal" screen. So this script leaves
# the Terminal's files alone and converts the Debian root filesystem from the inside:
#
#  1. install Nix from Debian, add the nixos and nixos-avf channels and build a system
#     with avf.terminal = 17
#  2. make it the system profile; the initScript loader writes /sbin/init for it
#  3. put a one-shot /sbin/init in front of it: on the next boot it moves Debian to
#     /old-root (what NixOS's initrd does for /etc/NIXOS_LUSTRATE; there is no NixOS
#     initrd here) and then starts NixOS
#
# Environment:
#   NIXOS_CHANNEL  nixpkgs channel (default: nixos-unstable)
#   AVF_CHANNEL    nixos-avf tarball providing <nixos-avf/avf>

set -euo pipefail

nixos_channel=${NIXOS_CHANNEL:-https://nixos.org/channels/nixos-unstable}
avf_channel=${AVF_CHANNEL:-https://github.com/slopmaxxer/nixos-avf/archive/refs/heads/android-17.tar.gz}
channels=/nix/var/nix/profiles/per-user/root/channels
system_profile=/nix/var/nix/profiles/system

die() {
  echo "error: $*" >&2
  exit 1
}

# --- checks -------------------------------------------------------------------------------

[ -e /system/build.prop ] && die "run this inside the Terminal app, not on Android"
[ "$(id -u)" = 0 ] || die "run it as root: sudo bash $0"
[ -e /etc/NIXOS ] && die "this already is NixOS"
[ -e /etc/debian_version ] || die "expected the Terminal's Debian system"
if mountpoint -q /mnt/internal || ! grep -qw 'root=/dev/vda1' /proc/cmdline; then
  die "this is not the Android 17 Terminal layout; on older Terminals use replace.sh"
fi

mem_mib=$(($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) / 1024))
if [ "$mem_mib" -lt 1900 ]; then
  die "building NixOS needs at least 2 GiB of VM memory, this VM has $mem_mib MiB; raise it in the Terminal settings"
fi

avail_mib=$(($(df -Pk / | awk 'NR == 2 { print $4 }') / 1024))
if [ "$avail_mib" -lt 6144 ]; then
  echo "warning: only $avail_mib MiB free on /, NixOS needs about 5 GiB." >&2
  echo "If the install runs out of space, enlarge the disk in the Terminal settings and run this again." >&2
fi

# --- 1. Nix and the system ----------------------------------------------------------------

if ! command -v nix-build >/dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends nix-bin
fi

# Build users for the sandbox, same ids as NixOS
getent group nixbld >/dev/null || groupadd -r -g 30000 nixbld
for i in $(seq 1 8); do
  id "nixbld$i" >/dev/null 2>&1 ||
    useradd -r -u $((30000 + i)) -g nixbld -G nixbld -d /var/empty -M -s /usr/sbin/nologin \
      -c "Nix build user $i" "nixbld$i"
done

export HOME=/root
nix-channel --add "$nixos_channel" nixos
nix-channel --add "$avf_channel" nixos-avf
nix-channel --update

export NIX_PATH="nixpkgs=$channels/nixos:nixos-config=/etc/nixos/configuration.nix:$channels"

if [ ! -e /etc/nixos/configuration.nix ]; then
  release=$(nix-instantiate --eval --expr '(import <nixpkgs/lib>).trivial.release' | tr -d '"')
  mkdir -p /etc/nixos
  cat >/etc/nixos/configuration.nix <<EOF
# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (\`nixos-help\`).

{ config, lib, pkgs, ... }:

{
  imports = [
    # include nixos-avf modules
    <nixos-avf/avf>
  ];

  # Android 17 Terminal: Debian's kernel boots /sbin/init on /dev/vda1
  avf.terminal = 17;

  # Change default user
  # avf.defaultUser = "droid";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "$release"; # Did you read the comment?
}
EOF
fi

echo "Building NixOS, this downloads about 1 GiB..."
system=$(nix-build --no-out-link '<nixpkgs/nixos>' -A system)
nix-env -p "$system_profile" --set "$system"

# --- 2. /sbin/init ------------------------------------------------------------------------

touch /etc/NIXOS
echo etc/nixos >/etc/NIXOS_LUSTRATE
NIXOS_INSTALL_BOOTLOADER=1 "$system_profile/bin/switch-to-configuration" boot

# --- 3. one-shot lustration in front of it --------------------------------------------------

# /sbin is Debian's symlink to usr/sbin; after the move the NixOS init is under /old-root
sbin=$(readlink -f /sbin)
mv /sbin/init "$sbin/init.nixos"
bash=$(readlink -f "$system/sw/bin/bash")
cat >/sbin/init <<EOF
#!$bash
# Written by nixos-avf's install-in-place.sh. Runs once as PID 1: moves Debian out of the
# way like NixOS's initrd does for /etc/NIXOS_LUSTRATE, then starts NixOS. No set -e: if
# anything fails, still try to boot.
export PATH=$system/sw/bin

echo
echo -e "\e[1;33m<<< nixos-avf: moving the Debian system to /old-root >>>\e[0m"
echo

# The root filesystem is mounted read-only. Name no device: Debian's fstab says
# PARTUUID=..., which can't be resolved without udev
mount -n -o remount,rw none /

shopt -s dotglob nullglob
mkdir -m 0755 -p /old-root.tmp
for entry in /*; do
  case "\$entry" in
    # possibly mounted already (devtmpfs is); stage 2 mounts the rest
    /nix | /dev | /proc | /run | /sys | /lost+found | /old-root.tmp) continue ;;
  esac
  mv "\$entry" /old-root.tmp/
done
mv /old-root.tmp /old-root

mkdir -m 0755 -p /etc /sbin /bin
touch /etc/NIXOS
while read -r keep; do
  mkdir -m 0755 -p "/\$(dirname "\$keep")"
  cp -a "/old-root/\$keep" "/\$keep"
done </old-root/etc/NIXOS_LUSTRATE

# NixOS's /sbin/init starts with #!/bin/sh, which only activation creates
ln -sfn $bash /bin/sh
cp -a /old-root$sbin/init.nixos /sbin/init

echo "Done. Delete /old-root once NixOS runs: sudo rm -rf /old-root"
exec $system_profile/init
EOF
chmod 0755 /sbin/init

echo
echo "NixOS is installed. Close the Terminal app (or run: sudo reboot) and open it again;"
echo "the first start moves Debian to /old-root and boots NixOS."
