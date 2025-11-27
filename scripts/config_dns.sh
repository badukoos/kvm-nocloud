#!/usr/bin/env bash
set -Eeuo pipefail

os_variant="${1:-}"
dns_csv="${2:-}"

if [ -z "$dns_csv" ]; then
  exit 0
fi

IFS=',' read -r -a dns_arr <<<"$dns_csv"

case "$os_variant" in
fedora*|rhel*|centos*)
  cat <<EOF
#cloud-config
write_files:
  - path: /etc/systemd/resolved.conf.d/10-kvm-nocloud.conf
    permissions: "0644"
    owner: root:root
    content: |
      [Resolve]
      DNS=$(printf "%s " "${dns_arr[@]}")

runcmd:
  - [ sh, -c, 'systemctl restart systemd-resolved || true' ]
EOF
  ;;
  ubuntu*|debian*)
    cat <<EOF
#cloud-config
manage_resolv_conf: true
resolv_conf:
  nameservers:
$(for ip in "${dns_arr[@]}"; do printf "    - %s\n" "$ip"; done)
EOF
    ;;
  *)
    cat <<EOF
#cloud-config
runcmd:
  - [ sh, -c, 'systemctl disable --now systemd-resolved 2>/dev/null || true; rm -f /etc/resolv.conf' ]
  - |
    cat > /etc/resolv.conf << 'EOF_RESOLV'
$(for ip in "${dns_arr[@]}"; do printf "      nameserver %s\n" "$ip"; done)
EOF
    ;;
esac
