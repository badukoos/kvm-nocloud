#!/usr/bin/env bash
set -eu

. /etc/os-release 2>/dev/null || true
ID="${ID:-unknown}"

warn() {
  printf "\033[1;33mWARN:\033[0m %s\n" "$*" >&2
}

package_install() {
  if command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt update || true
    apt install -y "$@" || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install "$@" || true
  else
    warn "No supported package manager found, skipping"
  fi
}

svc_enable() { systemctl enable "$@" 2>/dev/null || true; }
svc_start()  { systemctl start  "$@" 2>/dev/null || true; }

package_install openssh-server qemu-guest-agent || true

ssh-keygen -A || true
id vagrant >/dev/null 2>&1 || useradd -m -s /bin/bash vagrant
echo vagrant:vagrant | chpasswd

install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
[ -f /root/authorized_keys.vagrant ] && \
  install -m 600 -o vagrant -g vagrant /root/authorized_keys.vagrant /home/vagrant/.ssh/authorized_keys

echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/99_vagrant
chmod 440 /etc/sudoers.d/99_vagrant

svc_enable ssh  ; svc_start ssh  || true
svc_enable sshd ; svc_start sshd || true
svc_enable qemu-guest-agent ; svc_start qemu-guest-agent || true

case "$ID" in
  ubuntu)
    mkdir -p /etc/netplan
    cp /root/templates/netplan-dhcp.yaml /etc/netplan/99-vagrant-dhcp.yaml
    (command -v netplan >/dev/null 2>&1 && netplan generate || true)
    ;;
  debian)
    if [ -d /etc/systemd/network ]; then
      mkdir -p /etc/systemd/network
      cp /root/templates/systemd-networkd-dhcp.network /etc/systemd/network/99-vagrant.network
      svc_enable systemd-networkd || true
    fi
    ;;
  fedora|centos|rhel)
    svc_enable NetworkManager || true

    id vagrant >/dev/null 2>&1 || useradd -m -s /bin/bash vagrant
    mkdir -p /home/vagrant
    chown -R vagrant:vagrant /home/vagrant
    chmod 0755 /home
    chmod 0700 /home/vagrant
    mkdir -p /home/vagrant/.ssh
    [ -f /root/authorized_keys.vagrant ] && \
      install -m 600 -o vagrant -g vagrant /root/authorized_keys.vagrant /home/vagrant/.ssh/authorized_keys

    cp /root/templates/vagrant-selinux-fix.service /etc/systemd/system/vagrant-selinux-fix.service
    systemctl enable vagrant-selinux-fix.service || true
    # touch /.autorelabel
    ;;
  *) : ;;
esac

if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u || true
fi
