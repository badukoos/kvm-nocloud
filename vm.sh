#!/usr/bin/env bash
set -Eeuo pipefail

VM="${VM:-debian12}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"

# utils
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
for t in python3 curl sha256sum sha512sum virsh virt-install cloud-localds; do
  requires "$t"
done

[ -f inventory.toml ] || { echo "inventory.toml not found" >&2; exit 1; }

# toml helpers
toml_get(){ python3 - "$1" <<'PY'
import sys,json,tomllib
expr=sys.argv[1]
with open("inventory.toml","rb") as f: data=tomllib.load(f)
def get(d,p):
  cur=d
  for part in p.split('.'):
    if '[' in part and part.endswith(']'):
      k,i=part[:-1].split('[',1); cur=(cur or {}).get(k,[]); cur=cur[int(i)]
    else:
      cur=(cur or {}).get(part)
    if cur is None: return None
  return cur
print(json.dumps(get(data,expr)))
PY
}

toml_get_str() {
  v="$(toml_get "$1")"
  if [ "$v" = "null" ]; then
    echo ""
    return
  fi
  echo "$v" | tr -d '"'
}

toml_get_int() {
  raw="$(toml_get "$1")"
  def="${2:-}"
  [ "$raw" = "null" ] && raw=""
  raw="$(echo "$raw" | tr -d '"')"
  echo "${raw:-$def}"
}

vm_index() {
  n=$(toml_get "vm" | python3 -c 'import sys, json; print(len(json.load(sys.stdin) or []))')
  for i in $(seq 0 $((n - 1))); do
    this=$(toml_get "vm[$i].name" | tr -d '"')
    if [ "$this" = "$1" ]; then
      echo "$i"
      return
    fi
  done
}

IDX="$(vm_index "$VM")" || true
[ -n "$IDX" ] || error "No such virtual machine [$VM] in inventory.toml"

HOSTNAME="$(toml_get_str "vm[$IDX].hostname")"; [ -n "$HOSTNAME" ] || HOSTNAME="$VM"
OS_VARIANT="$(toml_get_str "vm[$IDX].os_variant")"; [ -n "$OS_VARIANT" ] || OS_VARIANT="$(toml_get_str defaults.os_variant)"; [ -n "$OS_VARIANT" ] || error "os_variant not defined for $VM or no defaults.os_variant found"

NET_NAME="$(toml_get_str defaults.net)"; [ -n "$NET_NAME" ]
virsh net-info "$NET_NAME" >/dev/null 2>&1 || error "libvirt network '$NET_NAME' not found"

MEM="$(toml_get_int "vm[$IDX].memory_mb" "$(toml_get_int defaults.memory_mb 2048)")"
VCPUS="$(toml_get_int "vm[$IDX].vcpus" "$(toml_get_int defaults.vcpus 2)")"

IMG_URL="$(toml_get_str "vm[$IDX].img_url")"; [ -n "$IMG_URL" ] || error "vm[$IDX].img_url not found"
IMG_NAME="$(basename -- "$IMG_URL")"
BASE_IMG="${IMAGES_DIR}/${IMG_NAME}"

SUMS_URL="$(toml_get_str "vm[$IDX].sums_url")"
SUMS_TYPE="$(toml_get_str "vm[$IDX].sums_type")"; [ -n "$SUMS_TYPE" ] || SUMS_TYPE="auto"

MODE="$(toml_get_str "vm[$IDX].mode")"; [ -n "$MODE" ] || MODE="dhcp"
MAC_ADDR="$(toml_get_str "vm[$IDX].mac")"

STATIC_IP="$(toml_get_str "vm[$IDX].ip")"
PREFIX="$(toml_get_int "vm[$IDX].prefix" "$(toml_get_int defaults.prefix 24)")"
DNS_JSON="$(toml_get "vm[$IDX].dns")"; [ "$DNS_JSON" = "null" ] && DNS_JSON="$(toml_get defaults.dns)"
DNS_LIST="$(echo "$DNS_JSON" | python3 -c 'import sys,json; a=json.load(sys.stdin); print(",".join(a) if a else "")')"
GW="$(toml_get_str "vm[$IDX].gw")"
if [ "$MODE" = "static" ]; then
  [ -n "$STATIC_IP" ] || error "Static mode requires ip="
  [ -n "$GW" ] || GW="$(echo "$STATIC_IP" | awk -F. '{printf "%d.%d.%d.1",$1,$2,$3}')"
fi
