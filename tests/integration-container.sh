#!/usr/bin/env bash
# Disposable Debian 12/13 container only. No host mounts except read-only source.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'This test requires a disposable Docker container' >&2; exit 1; }
SCRIPT=${1:?script path required}
[[ ! -e /var/lib/vps-tune ]] || { echo 'Test image contains existing vps-tune state' >&2; exit 1; }
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
# Pre-existing settings exercise restoration of the original files as well as
# removal of newly generated files. These fixtures exist only in this container.
mkdir -p /etc/sysctl.d /etc/modules-load.d
printf '# Original sysctl configuration\nnet.core.rmem_max = 65536\n' > /etc/sysctl.d/99-zz-vps-tune.conf
printf '# Original module choice\nsch_fq_codel\n' > /etc/modules-load.d/90-vps-tune.conf
for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    sed -i '/^[[:space:]]*session[[:space:]].*pam_limits\.so\([[:space:]]\|$\)/d' "$pam"
done
# One PAM stack already contains a valid limits rule; the other needs a rule.
printf '\nsession required pam_limits.so # existing local rule\n' >> /etc/pam.d/common-session-noninteractive

assert_unique_config() {
    awk -F= '
        /^[[:space:]]*[#;]/ || !index($0,"=") {next}
        {key=$1; gsub(/[[:space:]]/,"",key); sub(/^-/,"",key); gsub(/\//,".",key)
         if (++seen[key] > 1) {print "Duplicate sysctl: " key > "/dev/stderr"; exit 1}}
    ' /etc/sysctl.d/99-zz-vps-tune.conf
    [[ $(sort /var/lib/vps-tune/manifest | uniq -d | wc -l) == 0 ]]
    [[ $(cut -d= -f1 /var/lib/vps-tune/runtime.before | sort | uniq -d | wc -l) == 0 ]]
    local pam
    for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [[ $(grep -Ec '^[[:space:]]*session[[:space:]].*pam_limits\.so([[:space:]]|$)' "$pam") == 1 ]]
    done
}

managed_fingerprints() {
    local path
    while IFS= read -r path; do
        stat -c '%n %i %y' "$path"
        sha256sum "$path"
    done < /var/lib/vps-tune/manifest
}

backup_fingerprints() {
    find /var/lib/vps-tune/original -type f -print0 | sort -z | xargs -0 sha256sum
}

assert_queue() {
    local qdisc=$1
    assert_unique_config
    [[ $(grep -Ec '^-?net\.core\.default_qdisc[[:space:]]*=' /etc/sysctl.d/99-zz-vps-tune.conf) == 1 ]]
    grep -Fxq -- "-net.core.default_qdisc = $qdisc" /etc/sysctl.d/99-zz-vps-tune.conf
    [[ $(grep -Ec '^sch_' /etc/modules-load.d/90-vps-tune.conf) == 1 ]]
    grep -Fxq "sch_$qdisc" /etc/modules-load.d/90-vps-tune.conf
    [[ $(grep -Fxc tcp_bbr /etc/modules-load.d/90-vps-tune.conf) == 1 ]]
}

# Save actual configuration tree plus current kernel values. Container mode must
# never touch shared kernel sysctls, modprobe, services, boot or public traffic.
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.before"
sysctl net.core.somaxconn net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle > "$base/sysctl.before"
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --dry-run
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.dry"
cmp "$base/etc.before" "$base/etc.dry"
[[ ! -e /var/lib/vps-tune ]]
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --nofile 65536 --container-test
[[ -s /etc/sysctl.d/99-zz-vps-tune.conf ]]
grep -Fxq 'net.core.rmem_max = 14680064' /etc/sysctl.d/99-zz-vps-tune.conf
grep -Fxq 'net.core.wmem_max = 14680064' /etc/sysctl.d/99-zz-vps-tune.conf
[[ ! -s /var/lib/vps-tune/runtime.before ]]
assert_queue fq
managed_fingerprints > "$base/managed-first"
backup_fingerprints > "$base/backups-first"
cp /var/lib/vps-tune/manifest "$base/manifest-first"
for ((attempt=1; attempt<=3; attempt++)); do
    bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --nofile 65536 --container-test
    managed_fingerprints > "$base/managed-repeat"
    cmp "$base/managed-first" "$base/managed-repeat"
    cmp "$base/manifest-first" /var/lib/vps-tune/manifest
    assert_queue fq
done
bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 100 --nofile 262144 --container-test
grep -Fxq 'net.core.rmem_max = 27262976' /etc/sysctl.d/99-zz-vps-tune.conf
grep -Fxq 'net.ipv4.tcp_wmem = 4096 16384 27262976' /etc/sysctl.d/99-zz-vps-tune.conf
[[ $(awk '$3=="nofile" {if($4!=262144) exit 1; count++} END {print count}' /etc/security/limits.d/90-vps-tune.conf) == 4 ]]
for limits in /etc/systemd/system.conf.d/90-vps-tune.conf /etc/systemd/user.conf.d/90-vps-tune.conf; do
    [[ $(grep -Fxc 'DefaultLimitNOFILE=262144:262144' "$limits") == 1 ]]
done
[[ $(grep -Fxc 'LimitNOFILE=262144:262144' /etc/systemd/system/user@.service.d/90-vps-tune.conf) == 1 ]]
assert_unique_config
for qdisc in fq cake fq cake fq; do
    bash "$SCRIPT" queue --qdisc "$qdisc" --container-test
    assert_queue "$qdisc"
    managed_fingerprints > "$base/queue-first"
    bash "$SCRIPT" queue --qdisc "$qdisc" --container-test
    managed_fingerprints > "$base/queue-repeat"
    cmp "$base/queue-first" "$base/queue-repeat"
    assert_queue "$qdisc"
done
backup_fingerprints > "$base/backups-last"
cmp "$base/backups-first" "$base/backups-last"
cmp "$base/manifest-first" /var/lib/vps-tune/manifest
[[ ! -s /var/lib/vps-tune/runtime.before ]]
# Already-present PAM rules must still get the managed-file conflict check.
printf '# external edit after tuning\n' >> /etc/pam.d/common-session
cp /etc/pam.d/common-session "$base/pam-external"
if bash "$SCRIPT" apply --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 100 --nofile 262144 --container-test; then
    echo 'Apply ignored an external edit to the managed PAM file' >&2
    exit 1
fi
cmp "$base/pam-external" /etc/pam.d/common-session
backup_fingerprints > "$base/backups-after-conflict"
cmp "$base/backups-first" "$base/backups-after-conflict"
cp /var/lib/vps-tune/expected/etc/pam.d/common-session /etc/pam.d/common-session
bash "$SCRIPT" rollback --container-test
[[ ! -e /var/lib/vps-tune ]]
find /etc -type f -print0 | sort -z | xargs -0 sha256sum > "$base/etc.after"
cmp "$base/etc.before" "$base/etc.after"
sysctl net.core.somaxconn net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle > "$base/sysctl.after"
cmp "$base/sysctl.before" "$base/sysctl.after"
printf 'PASS container dry-run, idempotent apply/queue/PAM, changed values, original backups, rollback, and unchanged kernel values\n'
