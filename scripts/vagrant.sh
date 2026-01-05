#!/usr/bin/env bash
set -Eeuo pipefail

BOX_NAME="${BOX_NAME:-}"
SRC_IMG="${SRC_IMG:-}"
PROVIDER="${PROVIDER:-libvirt}"
OUT_DIR="${OUT_DIR:-build}"
VAGRANTFILE_SNIPPET="${VAGRANTFILE_SNIPPET:-}"
TARGET_SIZE_GB="${TARGET_SIZE_GB:-20}"
DIRECT_INSTALL="${DIRECT_INSTALL:-0}"

BOOTSTRAP_FILE="${BOOTSTRAP_FILE:-$(cd "$(dirname "$0")" && pwd -P)/vagrant_bootstrap.sh}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$(cd "$(dirname "$0")" && pwd -P)/templates}"

VAGRANT_PUBKEY="${VAGRANT_PUBKEY:-}"
VAGRANT_PUBKEY_URL="${VAGRANT_PUBKEY_URL:-https://raw.githubusercontent.com/mitchellh/vagrant/master/keys/vagrant.pub}"

info() {
  printf "\033[1;36mINFO:\033[0m %s\n" "$*"
}

error() {
  printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2
  exit 1
}

fetch_pubkey() {
  if [ -n "$VAGRANT_PUBKEY" ]; then
    printf '%s\n' "$VAGRANT_PUBKEY"; return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$VAGRANT_PUBKEY_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$VAGRANT_PUBKEY_URL"
  else
    error "Need curl or wget to fetch $VAGRANT_PUBKEY_URL or set VAGRANT_PUBKEY" >&2
    return 1
  fi
}

requires() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "missing tool: $1" >&2
    exit 1
  fi
}

for t in qemu-img virt-customize; do
  requires "$t"
done

[ -n "$BOX_NAME" ] || { error "BOX_NAME required" >&2; exit 1; }
[ -n "$SRC_IMG" ]  || { error "SRC_IMG required"  >&2; exit 1; }
[ -f "$SRC_IMG" ]  || { error "SRC_IMG not found: $SRC_IMG" >&2; exit 1; }
[ -r "$BOOTSTRAP_FILE" ] || { error "Bootstrap not readable: $BOOTSTRAP_FILE" >&2; exit 1; }
[ -d "$TEMPLATES_DIR" ] || { error "Templates dir missing: $TEMPLATES_DIR" >&2; exit 1; }

ktmp="$(mktemp)"
fetch_pubkey >"$ktmp" || { error "Failed to retrieve Vagrant public key"; exit 1; }
if ! head -c 12 "$ktmp" | grep -Eq '^(ssh-rsa|ssh-ed25519)\s'; then
  error "Downloaded key doesn't look like an SSH public key" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
workdir="$(mktemp -d -p /var/tmp vagrantbox.XXXXXX)"; trap 'rm -rf "$workdir"' EXIT
work_img="$workdir/src.qcow2"
cp --reflink=auto -- "$SRC_IMG" "$work_img" 2>/dev/null || cp -- "$SRC_IMG" "$work_img"
chmod 0644 "$work_img" 2>/dev/null || true

qemu-img resize "$work_img" "${TARGET_SIZE_GB}G" || true

export LIBGUESTFS_BACKEND=direct
if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  VIRT=(sudo --preserve-env=LIBGUESTFS_BACKEND virt-customize)
else
  VIRT=(virt-customize)
fi

vc=(-v -x --network -a "$work_img")
vc+=(
  --upload "$BOOTSTRAP_FILE:/root/bootstrap.sh"
  --upload "$ktmp:/root/authorized_keys.vagrant"
  --mkdir "/root/templates"
)

for f in "$TEMPLATES_DIR"/*; do
  [ -f "$f" ] && vc+=(--upload "$f:/root/templates/$(basename "$f")")
done

vc+=(--run-command 'chmod +x /root/bootstrap.sh && /root/bootstrap.sh')

set +e; "${VIRT[@]}" "${vc[@]}"; rc=$?; set -e
[ $rc -eq 0 ] || { error "virt-customize failed ($rc)"; exit $rc; }

vsize_gib="${TARGET_SIZE_GB}"
cp -f -- "$work_img" "$workdir/box.img"
cat >"$workdir/metadata.json" <<EOF
{
  "format": "qcow2",
  "provider": "$PROVIDER",
  "virtual_size": $vsize_gib
}
EOF

if [ -n "$VAGRANTFILE_SNIPPET" ] && [ -r "$VAGRANTFILE_SNIPPET" ]; then
  cp -f "$VAGRANTFILE_SNIPPET" "$workdir/Vagrantfile"
else
  cat >"$workdir/Vagrantfile" <<'EOF'
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
  end
end
EOF
fi

ver="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd -P)"

if [ "$DIRECT_INSTALL" = "1" ]; then
  # install directly into ~/.vagrant.d/boxes
  box_root="$HOME/.vagrant.d/boxes/localhost-VAGRANTSLASH-${BOX_NAME}/0/${PROVIDER}"
  info "Installing box directly into: $box_root"
  mkdir -p "$box_root"
  cp -f "$workdir"/{metadata.json,Vagrantfile,box.img} "$box_root/"
  info "Installed directly; no .box archive created"
else
  out_abs="${OUT_DIR_ABS}/${BOX_NAME}-${ver}-${PROVIDER}.box"
  ( cd "$workdir" && tar czf "$out_abs" metadata.json Vagrantfile box.img )
  info "Built box $out_abs"
fi
