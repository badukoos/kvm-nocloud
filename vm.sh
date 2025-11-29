#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

VM="${VM:-}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images/local}"
SEED_IMG="${SEED_IMG:-${IMAGES_DIR}/${VM}-seed.img}"
WAIT_SSH_SECS="${WAIT_SSH_SECS:-90}"
INV="${INV:-${ROOT_DIR}/inventory.yml}"
umask 002

DESTROY="${DESTROY:-0}"
PURGE_DISKS="${PURGE_DISKS:-0}"
REBUILD="${REBUILD:-0}"
KEEP_INSTANCE_ID="${KEEP_INSTANCE_ID:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
FORCE_DS="${FORCE_DS:-0}"

VAGRANT_BOX="${VAGRANT_BOX:-0}"
BOX_NAME="${BOX_NAME:-$VM}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/boxes}"
VAGRANTFILE_SNIPPET="${VAGRANTFILE_SNIPPET:-}"

usage() {
  cat <<EOF
Usage:
  VM=<name> [ENV=...] ${0}

Description:
  Build a libvirt VM defined in inventory.yml

Environment flags:
  VM                  Name of the VM entry in inventory.yml

  DESTROY=1           Destroy and undefine the existing domain
  PURGE_DISKS=1       Used with DESTROY=1, also removes
                        - \${IMAGES_DIR}/\${VM}.qcow2
                        - seed image i.e. \${SEED_IMG}
  REBUILD=1           Force re-download of the base image and recreate \${VM}.qcow2
  KEEP_INSTANCE_ID=1  Use a stable instance-id "\${VM}-stable" so cloud-init
                      treats rebuilds as the same instance
  SKIP_VERIFY=1       Skip checksum verification of the downloaded base image
  FORCE_DS=1          Add "ds=nocloud;s=/dev/vdb/" to qemu cmdline via virt-install

  IMAGES_DIR          Directory for base images and VM disks
                        Default: /var/lib/libvirt/images/local
  SEED_IMG            Path to the NoCloud seed image
                        Default: \${IMAGES_DIR}/\${VM}-seed.img

  WAIT_SSH_SECS       Seconds to wait for SSH to come up after boot
                        Default: 90

  INV                 Path to inventory
                        Default: <root_dir>/inventory.yml

  VIRT_XML            Extra --xml fragments to append separated by ';'
                        Example:
                          VIRT_XML='cpu mode=host-passthrough;features pmu=on'
  VIRT_XML_FILE       Path to a file containing additional --xml lines
                        Each non-empty non-comment line becomes an --xml arg

Vagrant options:
  VAGRANT_BOX=1       Package a libvirt .box from the prepared base image and exit

  BOX_NAME            Vagrant box name
                        Default: \$VM
  OUT_DIR             Output directory for the .box
                        Default: <root_dir>/build/boxes
  VAGRANTFILE_SNIPPET Optional Vagrantfile snippet to embed inside the box

  DIRECT_INSTALL=1    Handled by scripts/vagrant.sh
                      Install directly into:
                        ~/.vagrant.d/boxes/localhost-VAGRANTSLASH-\${BOX_NAME}/0/libvirt
                      instead of creating a .box archive.

  TARGET_SIZE_GB      Handled by scripts/vagrant.sh
                      Target virtual disk size in GB when boxing
                        Default: 20

  BOOTSTRAP_FILE      Path to the Vagrant bootstrap script used by vagrant.sh
                      Currently scripts/vagrant_bootstrap.sh
                        Default: <root_dir>/scripts/vagrant_bootstrap.sh
  TEMPLATES_DIR       Directory containing templates consumed by the bootstrap
                        Default: <root_dir>/templates

  -h, --help          Show this help

EOF
}
for a in "$@"; do
  case "$a" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument $a" >&2
      exit 1
      ;;
  esac
done

info() {
  printf "\033[1;36mINFO:\033[0m %s\n" "$*"
}
warn() {
  printf "\033[1;33mWARN:\033[0m %s\n" "$*" >&2
}
error() {
  printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2
  exit 1
}
requires() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing tool: $1" >&2
    exit 1
  fi
}

for t in curl sha256sum sha512sum virsh virt-install cloud-localds dasel; do
  requires "$t"
done

[ -f "$INV" ] || { echo "inventory YAML not found: $INV" >&2; exit 1; }
sudo mkdir -p "$IMAGES_DIR"
CURL_FLAGS="--retry 3 --retry-delay 2 --retry-connrefused"

run_pretty() {
  set +e
  stdbuf -oL -eL "$@" 2>&1 | awk 'NF'
  rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

yaml_get() {
  local expr="$1"
  yq -r ".${expr}" "$INV" 2>/dev/null || true
}

yaml_get_json() {
  local expr="$1"
  yq -o=json ".${expr}" "$INV" 2>/dev/null || true
}

yaml_get_str() {
  local v
  v="$(yaml_get "$1")"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    echo ""
    return
  fi
  echo "$v"
}

yaml_get_int() {
  local raw def
  raw="$(yaml_get "$1" | tr -d '"' | xargs || true)"
  def="${2:-}"
  if [ -n "$raw" ] && [ "$raw" != "null" ] && [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$def"
  fi
}

yaml_get_list() {
  local expr="$1"
  yq -r ".${expr}[]" "$INV" 2>/dev/null \
    | sed '/^null$/d' \
    || true
}

yaml_get_multiline() {
  local expr="$1" v
  v="$(yaml_get "$expr")"
  [ -z "$v" ] || [ "$v" = "null" ] && return 0
  printf '%s\n' "$v"
}

yaml_vm_index() {
  local name="$1"
  local i=0 cur
  while :; do
    cur="$(yq -r ".vm[$i].name // \"\"" "$INV" 2>/dev/null || true)"
    [ -z "$cur" ] && break
    cur="$(echo "$cur" | xargs)"
    if [ "$cur" = "$name" ]; then
      printf '%s\n' "$i"
      return 0
    fi
    i=$((i+1))
  done
  return 1
}

build_xml_args() {
  XML_ARGS=()

  while IFS= read -r line; do
    [ -n "$line" ] && XML_ARGS+=( --xml "$line" )
  done < <(yaml_get_list "defaults.xml")

  while IFS= read -r line; do
    [ -n "$line" ] && XML_ARGS+=( --xml "$line" )
  done < <(yaml_get_list "vm[$IDX].xml")

  if [ -n "${VIRT_XML:-}" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(printf '%s' "$line" | xargs)"
      [ -n "$line" ] && XML_ARGS+=( --xml "$line" )
    done < <(printf '%s\n' "$VIRT_XML" | tr ';' '\n')
  fi

  if [ -n "${VIRT_XML_FILE:-}" ] && [ -r "$VIRT_XML_FILE" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(printf '%s' "$line" | xargs)"
      [ -n "$line" ] && XML_ARGS+=( --xml "$line" )
    done < "$VIRT_XML_FILE"
  fi
}

[ -n "$VM" ] || error "VM not set (use VM=<name>)"

IDX="$(yaml_vm_index "$VM")" || true
[ -n "$IDX" ] || error "No such virtual machine [$VM] in $INV"

HOSTNAME="$(yaml_get_str "vm[$IDX].hostname")"; [ -n "$HOSTNAME" ] || HOSTNAME="$VM"
OS_VARIANT="$(yaml_get_str "vm[$IDX].os_variant")"
[ -n "$OS_VARIANT" ] || OS_VARIANT="$(yaml_get_str defaults.os_variant)"
[ -n "$OS_VARIANT" ] || error "os_variant not defined for $VM and/or no defaults.os_variant found"

NET_NAME="$(yaml_get_str defaults.net)"; [ -n "$NET_NAME" ]
virsh net-info "$NET_NAME" >/dev/null 2>&1 || error "libvirt network '$NET_NAME' not found"

MEM="$(yaml_get_int "vm[$IDX].memory_mb" "$(yaml_get_int defaults.memory_mb 2048)")"
VCPUS="$(yaml_get_int "vm[$IDX].vcpus" "$(yaml_get_int defaults.vcpus 2)")"

IMG_URL="$(yaml_get_str "vm[$IDX].img_url")"; [ -n "$IMG_URL" ] || error "vm[$IDX].img_url not found"
IMG_NAME="$(basename -- "$IMG_URL")"
BASE_IMG="${IMAGES_DIR}/${IMG_NAME}"

SUMS_URL="$(yaml_get_str "vm[$IDX].sums_url")"
SUMS_TYPE="$(yaml_get_str "vm[$IDX].sums_type")"; [ -n "$SUMS_TYPE" ] || SUMS_TYPE="auto"

MODE="$(yaml_get_str "vm[$IDX].mode")"; [ -n "$MODE" ] || MODE="dhcp"
MAC_ADDR="$(yaml_get_str "vm[$IDX].mac")"

STATIC_IP="$(yaml_get_str "vm[$IDX].ip")"
PREFIX="$(yaml_get_int "vm[$IDX].prefix" "$(yaml_get_int defaults.prefix 24)")"

DNS_LIST="$(yaml_get_list "vm[$IDX].dns")"
if [ -z "$DNS_LIST" ]; then
  DNS_LIST="$(yaml_get_list defaults.dns)"
fi
if [ -n "$DNS_LIST" ]; then
  DNS_LIST="$(printf "%s\n" "$DNS_LIST" | paste -sd "," -)"
fi

DNS_CFG=""
if [ -n "$DNS_LIST" ]; then
  DNS_CFG="$("${ROOT_DIR}/scripts/config_dns.sh" "$OS_VARIANT" "$DNS_LIST" || true)"
fi

GW="$(yaml_get_str "vm[$IDX].gw")"
if [ "$MODE" = "static" ]; then
  [ -n "$STATIC_IP" ] || error "Static mode requires ip="
  [ -n "$GW" ] || GW="$(echo "$STATIC_IP" | awk -F. '{printf "%d.%d.%d.1",$1,$2,$3}')"
fi

SSH_USER="$(yaml_get_str defaults.ssh_user)"; [ -n "$SSH_USER" ]
SSH_KEY_PATH="$(yaml_get_str defaults.ssh_key)"; [ -n "$SSH_KEY_PATH" ]
[ -r "$SSH_KEY_PATH" ] || error "SSH key not readable $SSH_KEY_PATH"
SSH_PUB="$(cat "$SSH_KEY_PATH".pub 2>/dev/null || ssh-keygen -y -f "$SSH_KEY_PATH" 2>/dev/null || true)"
[ -n "$SSH_PUB" ] || error "Could not obtain public key from $SSH_KEY_PATH.pub"

if [ "$DESTROY" = "1" ]; then
  info "Destroying domain"
  ( virsh destroy "$VM" >/dev/null 2>&1 ) || true
  info "Undefining domain"
  ( virsh undefine "$VM" --nvram >/dev/null 2>&1 ) || true
  if [ "$PURGE_DISKS" = "1" ]; then
    info "Purging VM disks & seed"
    sudo rm -f "${IMAGES_DIR}/${VM}.qcow2" "$SEED_IMG" >/dev/null 2>&1 || true
  fi
  info "Done"
  exit 0
fi

verify_image() {
  [ -n "$SUMS_URL" ] && [ "$SKIP_VERIFY" != "1" ] || { warn "Verification skipped"; return 0; }

  local sums one rc=2
  sums="$(mktemp -t vm-"${IMG_NAME}".SUMS.XXXXXX)"
  one=""

  cleanup_verify(){ [ -n "$one" ] && rm -f "$one"; rm -f "$sums"; }
  trap cleanup_verify RETURN

  curl -fsSLo "$sums" $CURL_FLAGS "$SUMS_URL" || return 2

  try_sha512() { ( cd "$IMAGES_DIR" && sha512sum -c --ignore-missing "$sums" ); }
  try_sha256() { ( cd "$IMAGES_DIR" && sha256sum -c --ignore-missing "$sums" ); }
  try_fedora() {
    one="$(mktemp -t vm-"${IMG_NAME}".ONE.XXXXXX)"
    awk -v f="$IMG_NAME" 'toupper($1)=="SHA256" && $2 ~ /^\(.*\)$/ && $3=="=" {
      file=$2; sub(/^\(/,"",file); sub(/\)$/,"",file);
      if (file==f) print $4"  "f
    }' "$sums" >"$one"
    [ -s "$one" ] || return 2
    ( cd "$IMAGES_DIR" && sha256sum -c "$one" )
  }

  case "$SUMS_TYPE" in
    sha512)  try_sha512; rc=$? ;;
    sha256)  try_sha256; rc=$? ;;
    fedora-checksum) try_fedora; rc=$? ;;
    auto|"")
      try_sha512; rc=$?
      [ "$rc" -eq 0 ] || { try_sha256; rc=$?; }
      [ "$rc" -eq 0 ] || { try_fedora; rc=$?; }
      ;;
    *) rc=2 ;;
  esac

  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

info "Download image into ${IMAGES_DIR}"
TMP_DL="${BASE_IMG}.part"
need_download=0

if sudo test -e "$TMP_DL" && ! sudo test -s "$TMP_DL"; then
  warn "Removing stale files"
  sudo rm -f "$TMP_DL"
fi

if [ "$REBUILD" = "1" ]; then
  info "REBUILD=1 is set, this will re download base image"
  need_download=1
  sudo rm -f "$BASE_IMG" "$TMP_DL" 2>/dev/null || true
fi

if [ "$need_download" = "0" ]; then
  if [ -f "$BASE_IMG" ]; then
    if verify_image; then
      info "Base image verified OK, skipping download"
      [ -f "$TMP_DL" ] && sudo rm -f "$TMP_DL"
      need_download=0
    else
      case "$?" in
        1) warn "Checksum mismatch, re-downloading image"; need_download=1 ;;
        2) warn "No matching checksum or unrecognized SUMS, skipping download";
           [ -f "$TMP_DL" ] && sudo rm -f "$TMP_DL"
           need_download=0 ;;
      esac
    fi
  else
    need_download=1
  fi
fi

if [ "$need_download" = "1" ]; then
  if [ -f "$TMP_DL" ]; then
    info "Resuming partial download $(basename "$TMP_DL")"
    sudo sh -c "curl -fSLo '$TMP_DL' $CURL_FLAGS -C - '$IMG_URL'"
  else
    info "Starting download $(basename "$BASE_IMG")"
    sudo sh -c "curl -fSLo '$TMP_DL' $CURL_FLAGS '$IMG_URL'"
  fi

  if ! sudo test -s "$TMP_DL"; then
    sudo rm -f "$TMP_DL"
    error "download produced empty file"
  fi

  info "Installing image to $BASE_IMG"
  sudo mv -f "$TMP_DL" "$BASE_IMG"
  sudo chown qemu:qemu "$BASE_IMG" 2>/dev/null || true
  # check context manually ls -Z /var/lib/libvirt/images/
  sudo chcon -t svirt_image_t "$BASE_IMG" 2>/dev/null || true

  if ! verify_image; then
    case "$?" in
      1) sudo rm -f "$BASE_IMG"; error "Checksum mismatch for ${IMG_NAME}" ;;
      2) warn "Checksum inconclusive for ${IMG_NAME}" ;;
    esac
  else
    info "Checksum OK"
  fi
fi

if [ "$VAGRANT_BOX" = "1" ]; then
  info "Packaging Vagrant box from $BASE_IMG"
  [ -x "${ROOT_DIR}/scripts/vagrant.sh" ] || error "vagrant.sh not found or not executable"

  : "${BOOTSTRAP_FILE:=${ROOT_DIR}/scripts/vagrant_bootstrap.sh}"
  : "${TEMPLATES_DIR:=${ROOT_DIR}/templates}"

  BOX_NAME="$BOX_NAME" \
  SRC_IMG="$BASE_IMG" \
  PROVIDER="libvirt" \
  OUT_DIR="$OUT_DIR" \
  BAKE_VAGRANT="${BAKE_VAGRANT:-0}" \
  VAGRANTFILE_SNIPPET="${VAGRANTFILE_SNIPPET:-}" \
  BOOTSTRAP_FILE="$BOOTSTRAP_FILE" \
  TEMPLATES_DIR="$TEMPLATES_DIR" \
  "${ROOT_DIR}/scripts/vagrant.sh"

  info "Box created. Done."
  exit 0
fi

VM_DISK="${IMAGES_DIR}/${VM}.qcow2"
if [ "$REBUILD" = "1" ]; then
  info "Recreating VM disk at $VM_DISK"
  sudo rm -f "$VM_DISK"
fi
if [ ! -f "$VM_DISK" ]; then
  if sudo cp --reflink=auto "$BASE_IMG" "$VM_DISK" 2>/dev/null; then
    info "Created disk via reflink $VM_DISK"
  else
    warn "Reflink unavailable, cloning base into $VM_DISK"
    sudo cp -f "$BASE_IMG" "$VM_DISK"
  fi
  sudo chown qemu:qemu "$VM_DISK" 2>/dev/null || true
  sudo chcon -t svirt_image_t "$VM_DISK" 2>/dev/null || true
else
  info "Disk already exists at $VM_DISK"
fi

INSTANCE_ID="${VM}-$(date -u +%Y%m%dT%H%M%SZ)"
[ "$KEEP_INSTANCE_ID" = "1" ] && INSTANCE_ID="${VM}-stable"

META_FILE="$(mktemp)"
cat >"$META_FILE" <<EOF
instance-id: ${INSTANCE_ID}
local-hostname: ${HOSTNAME}
EOF

emit_net=0
NET_FILE=""

if [ "$MODE" = "static" ]; then
  [ -n "$MAC_ADDR" ] && [ "$MAC_ADDR" != "auto" ] || error "static mode requires a pinned MAC"
  NET_FILE="$(mktemp)"
  {
    echo "version: 2"
    echo "ethernets:"
    echo "  id0:"
    echo "    match: { macaddress: ${MAC_ADDR} }"
    echo "    addresses: [ ${STATIC_IP}/${PREFIX} ]"
    echo "    routes: [ { to: 0.0.0.0/0, via: ${GW} } ]"
    echo "    dhcp-identifier: mac"
    [ -n "$DNS_LIST" ] && echo "    nameservers: { addresses: [$(echo "${DNS_LIST}" | sed 's/,/, /g')] }"
  } >"$NET_FILE"
  emit_net=1
elif [ -n "$MAC_ADDR" ] && [ "$MAC_ADDR" != "auto" ]; then
  NET_FILE="$(mktemp)"
  cat >"$NET_FILE" <<EOF
version: 2
ethernets:
  id0:
    match: { macaddress: ${MAC_ADDR} }
    dhcp4: true
    dhcp6: false
    dhcp-identifier: mac
EOF
  emit_net=1
fi

USER_FILE="$(mktemp)"
BOUND="BOUNDARY-$(date +%s%N)"

DEF_YAML="$(yaml_get_multiline defaults.userdata_yaml)"
VM_YAML="$(yaml_get_multiline "vm[$IDX].userdata_yaml")"

if [ -z "$DEF_YAML" ] && [ -z "$VM_YAML" ] && [ -z "$DNS_CFG" ]; then
  error "No cloud-config found in $INV"
fi

{
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"$BOUND\""
  echo
  if [ -n "$DEF_YAML" ] ; then
    echo "--$BOUND"
    echo "Content-Type: text/cloud-config"
    echo
    printf "%s\n" "$DEF_YAML"
  fi
  if [ -n "$VM_YAML" ] ; then
    echo "--$BOUND"
    echo "Content-Type: text/cloud-config"
    echo
    printf "%s\n" "$VM_YAML"
  fi
  if [ -n "$DNS_CFG" ] ; then
    echo "--$BOUND"
    echo "Content-Type: text/cloud-config"
    echo
    printf "%s\n" "$DNS_CFG"
  fi
  echo "--$BOUND--"
} > "$USER_FILE"

info "Creating seed image"
if [ "$emit_net" -eq 1 ]; then
  sudo cloud-localds --network-config="$NET_FILE" "$SEED_IMG" "$USER_FILE" "$META_FILE"
else
  # used when mode=dhcp, mac=auto
  sudo cloud-localds "$SEED_IMG" "$USER_FILE" "$META_FILE"
fi

sudo chcon -t svirt_image_t "$SEED_IMG" 2>/dev/null || true
sudo rm -f "$META_FILE" "$USER_FILE" 2>/dev/null || true
[ -n "$NET_FILE" ] && sudo rm -f "$NET_FILE"

NET_ARG="network=${NET_NAME},model=virtio"
[ -n "$MAC_ADDR" ] && [ "$MAC_ADDR" != "auto" ] && NET_ARG="${NET_ARG},mac=${MAC_ADDR}"

EXTRA_ARGS=()
[ "$FORCE_DS" = "1" ] && EXTRA_ARGS+=( --qemu-commandline "-append ds=nocloud;s=/dev/vdb/" )

build_xml_args

info "Launching virtual machine"
if run_pretty virt-install \
  --name "$VM" \
  --os-variant "$OS_VARIANT" \
  --memory "$MEM" \
  --vcpus "$VCPUS" \
  --disk "path=$VM_DISK,format=qcow2,bus=virtio,target.dev=vda" \
  --disk "path=$SEED_IMG,format=raw,device=disk,bus=virtio,target.dev=vdb" \
  --network "$NET_ARG" \
  --import \
  --boot hd,menu=on \
  --graphics spice \
  --noautoconsole \
  --check path_in_use=off \
  "${XML_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"; then
  info "Virtual machine launched"
else
  error "virt-install failed"
fi

if [ -z "$MAC_ADDR" ] || [ "$MAC_ADDR" = "auto" ]; then
  MAC_ADDR="$(virsh dumpxml "$VM" | awk -F"'" '/mac address=/{print $2; exit}')"
  [ -n "$MAC_ADDR" ] || error "Could not read MAC from domain XML"
fi

TARGET_IP=""
if [ "$MODE" = "static" ]; then
  TARGET_IP="$STATIC_IP"
else
  info "Waiting for DHCP lease on $NET_NAME"
  ddl=$(( $(date +%s) + WAIT_SSH_SECS ))
  while [ "$(date +%s)" -lt "$ddl" ]; do
    ip="$(virsh net-dhcp-leases "$NET_NAME" 2>/dev/null | awk -v mac="$MAC_ADDR" '
      tolower($0) ~ tolower(mac) {
        for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) {print $i; exit}
      }')"
    if [ -n "$ip" ]; then TARGET_IP="${ip%%/*}"; break; fi
    sleep 1
  done
  [ -n "$TARGET_IP" ] || error "Could not discover DHCP lease for $MAC_ADDR on $NET_NAME"
  info "Discovered lease: $TARGET_IP"
fi

info "Waiting up to ${WAIT_SSH_SECS}s for SSH on ${TARGET_IP}"
ddl=$(( $(date +%s) + WAIT_SSH_SECS ))
ok=0
while [ "$(date +%s)" -lt "$ddl" ]; do
  if timeout 2 bash -c "</dev/tcp/${TARGET_IP}/22" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
if [ "$ok" = "1" ]; then
  info "Setup complete"
else
  error "SSH did not come up in time"
fi
