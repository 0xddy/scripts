#!/usr/bin/env bash
# Disposable Debian 12/13 container only. No host mounts except read-only source.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'This test requires a disposable Docker container' >&2; exit 1; }
SCRIPT=${1:?script path required}
[[ ! -e /var/lib/vps-tune ]] || { echo 'Test image contains existing vps-tune state' >&2; exit 1; }
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
# Save actual configuration tree plus current kernel values. Container mode must
# never touch shared kernel sysctls, modprobe, services, boot or public traffic.
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.before"
sysctl net.core.somaxconn net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle > "$base/sysctl.before"
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --dry-run
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.dry"
cmp "$base/etc.before" "$base/etc.dry"
[[ ! -e /var/lib/vps-tune ]]
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --container-test
[[ -s /etc/sysctl.d/99-zz-vps-tune.conf ]]
grep -Fxq 'net.core.rmem_max = 14680064' /etc/sysctl.d/99-zz-vps-tune.conf
grep -Fxq 'net.core.wmem_max = 14680064' /etc/sysctl.d/99-zz-vps-tune.conf
[[ ! -s /var/lib/vps-tune/runtime.before ]]
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 100 --container-test
grep -Fxq 'net.core.rmem_max = 27262976' /etc/sysctl.d/99-zz-vps-tune.conf
bash "$SCRIPT" rollback --container-test
[[ ! -e /var/lib/vps-tune ]]
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.after"
cmp "$base/etc.before" "$base/etc.after"
sysctl net.core.somaxconn net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle > "$base/sysctl.after"
cmp "$base/sysctl.before" "$base/sysctl.after"
printf 'PASS actual container dry-run, apply, reapply, rollback, and kernel values unchanged\n'
