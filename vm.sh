#!/usr/bin/env bash
set -Eeuo pipefail

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