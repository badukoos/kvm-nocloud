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
