#!/usr/bin/env bash
# Download official static tools for disposable Docker tests; never measure WAN.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Disposable Docker container required'; exit 1; }
source "${1:-/src/vps-tune.sh}"
destination=${2:-/tmp/singbox-runtime-fixtures}
mkdir -p "$destination"
case $(uname -m) in
    x86_64) ookla_arch=x86_64; jq_arch=amd64 ;;
    aarch64) ookla_arch=aarch64; jq_arch=arm64 ;;
    *) die 'Unsupported test architecture' ;;
esac
# Production helper verifies the pinned SHA256 before executing either tool.
fetch_https "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$ookla_arch.tgz" "$destination/ookla.tgz"
fetch_https "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-$jq_arch" "$destination/jq"
