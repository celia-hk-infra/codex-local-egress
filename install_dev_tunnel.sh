#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: bash install_dev_tunnel.sh\nInstall Microsoft Dev Tunnels for Linux (x86_64 or ARM64) in ~/.local/bin.\n'
  exit 0
fi

if [[ $# -ne 0 ]]; then
  printf 'Unknown argument. Use --help.\n' >&2
  exit 1
fi
if [[ "$(uname -s)" != Linux ]]; then
  printf 'This installer supports Linux only (including WSL).\n' >&2
  exit 1
fi
case "$(uname -m)" in
  x86_64) arch=linux-x64 ;;
  aarch64|arm64) arch=linux-arm64 ;;
  *) printf 'Unsupported CPU architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
command -v curl >/dev/null || { printf 'curl is required.\n' >&2; exit 1; }

install_dir="$HOME/.local/bin"
mkdir -p "$install_dir"
tmp="$(mktemp "$install_dir/.devtunnel-download.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl --fail --location --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  "https://aka.ms/TunnelsCliDownload/$arch" -o "$tmp"
chmod 755 "$tmp"
if ! "$tmp" --version; then
  printf 'Downloaded devtunnel could not run; existing installation was not changed.\nIf ICU libraries are missing, see README section 2.4.\n' >&2
  exit 1
fi
mv -f "$tmp" "$install_dir/devtunnel"
printf '\nInstalled: %s/devtunnel\n' "$install_dir"
printf 'Next: copy connection.env, then run bash remote.sh devtunnel login github and bash remote.sh.\n'
printf 'For direct devtunnel commands in this shell: export PATH="$HOME/.local/bin:$PATH"\n'
