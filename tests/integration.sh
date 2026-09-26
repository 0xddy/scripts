#!/usr/bin/env bash
# Destructive to this disposable container's configuration. Never run on a host.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Tests require a disposable Docker container'; exit 1; }
SCRIPT=${1:-/src/vps-tune.sh}
SCRATCH=$(mktemp -d)
trap 'rm -rf -- "$SCRATCH"' EXIT
passed=0
pass() { printf 'PASS %s\n' "$*"; passed=$((passed + 1)); }
expect_failure() { if "$@" > "$SCRATCH/negative.log" 2>&1; then cat "$SCRATCH/negative.log"; echo "Unexpected success: $*"; exit 1; fi; }
bash -n "$SCRIPT"
shellcheck "$SCRIPT"
pass 'Bash syntax and ShellCheck'

if [[ -s /var/lib/singbox-tune/manifest ]]; then bash "$SCRIPT" rollback --container-test; fi
[[ ! -e /var/lib/singbox-tune ]]
cp -a /etc/pam.d/common-session "$SCRATCH/common-session"
cp -a /etc/pam.d/common-session-noninteractive "$SCRATCH/common-session-noninteractive"
mkdir -p /etc/security/limits.d
printf '# original fixture: preserve on rollback\n' > /etc/security/limits.d/90-singbox-tune.conf

bash "$SCRIPT" --dry-run --kernel skip
[[ ! -e /var/lib/singbox-tune ]]
expect_failure bash "$SCRIPT" --kernel skip
expect_failure bash "$SCRIPT" --container-test --reboot
expect_failure bash "$SCRIPT" --container-test --nofile 0
expect_failure bash "$SCRIPT" --container-test --service ../../bad
if grep -q 'VERSION_ID="12"' /etc/os-release; then expect_failure bash "$SCRIPT" --dry-run --kernel main; fi
pass 'Read-only dry run and input/container guards'

sysctl -n fs.file-max fs.nr_open net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem > "$SCRATCH/runtime"
bash "$SCRIPT" --container-test --kernel skip --buffer-mib 16
sysctl -n fs.file-max fs.nr_open net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem > "$SCRATCH/runtime.after"
cmp "$SCRATCH/runtime" "$SCRATCH/runtime.after"
[[ ! -s /var/lib/singbox-tune/runtime.before ]]
pass 'Container test makes no runtime sysctl writes'

cp /var/lib/singbox-tune/manifest "$SCRATCH/manifest"
while read -r file; do sha256sum "$file"; done < "$SCRATCH/manifest" > "$SCRATCH/sums"
bash "$SCRIPT" --container-test --kernel skip --buffer-mib 16
cmp "$SCRATCH/manifest" /var/lib/singbox-tune/manifest
sha256sum -c "$SCRATCH/sums"
[[ $(sort /var/lib/singbox-tune/manifest | uniq -d | wc -l) == 0 ]]
pass 'Repeated apply is byte-identical and preserves first backup'

grep -qx 'DefaultLimitNOFILE=1048576:1048576' /etc/systemd/system.conf.d/90-singbox-tune.conf
grep -qx 'DefaultLimitNOFILE=1048576:1048576' /etc/systemd/user.conf.d/90-singbox-tune.conf
grep -qx 'LimitNOFILE=1048576:1048576' /etc/systemd/system/user@.service.d/90-singbox-tune.conf
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=singbox-tune integration fixture
[Service]
ExecStart=/bin/sleep infinity
EOF
systemd-analyze verify /etc/systemd/system/sing-box.service
systemd-analyze cat-config systemd/system.conf | grep -qx 'DefaultLimitNOFILE=1048576:1048576'
pass 'Systemd default/user/service configuration parses offline'

for who in root nobody; do
    result=$( (ulimit -Sn 1024; su -s /bin/sh "$who" -c 'ulimit -Sn; ulimit -Hn') )
    [[ $result == $'1048576\n1048576' ]]
done
pass 'Real PAM sessions for root and nobody lift soft limit from 1024 to 1048576'
su -s /bin/sh nobody -c "python3 -c 'import os, resource; fds=[os.open(\"/dev/null\", os.O_RDONLY) for _ in range(65536)]; print(\"opened\",len(fds),\"FDs; limits=\",resource.getrlimit(resource.RLIMIT_NOFILE)); [os.close(fd) for fd in fds]'"
pass 'Unprivileged PAM child opens 65536 actual file descriptors'

set +e
bash "$SCRIPT" check > "$SCRATCH/check.log" 2>&1
code=$?
set -e
[[ $code == 2 ]]
pass 'Check reports unverified runtime with exit 2 in container'

cp /etc/sysctl.d/99-zz-singbox-tune.conf "$SCRATCH/sysctl"
printf '\n# independent administrator edit\n' >> /etc/sysctl.d/99-zz-singbox-tune.conf
expect_failure bash "$SCRIPT" --container-test --kernel skip
expect_failure bash "$SCRIPT" rollback --container-test
cp "$SCRATCH/sysctl" /etc/sysctl.d/99-zz-singbox-tune.conf
pass 'Reapply/rollback refuse to overwrite later edits'

bash "$SCRIPT" rollback --container-test --dry-run
[[ -f /etc/sysctl.d/99-zz-singbox-tune.conf ]]
bash "$SCRIPT" rollback --container-test
[[ ! -e /etc/sysctl.d/99-zz-singbox-tune.conf ]]
grep -qx '# original fixture: preserve on rollback' /etc/security/limits.d/90-singbox-tune.conf
cmp /etc/pam.d/common-session "$SCRATCH/common-session"
cmp /etc/pam.d/common-session-noninteractive "$SCRATCH/common-session-noninteractive"
pass 'Rollback restores original files and removes only created files'
rm /etc/security/limits.d/90-singbox-tune.conf

(
    # CPU fixtures test minimum feature level across heterogeneous vCPUs.
    # shellcheck disable=SC1090
    source "$SCRIPT"
    printf 'flags : lm sse sse2\n' > "$SCRATCH/cpu-v1"
    printf 'flags : cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2\n' > "$SCRATCH/cpu-v2"
    printf 'flags : cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave\n' > "$SCRATCH/cpu-v3"
    [[ $(cpu_level "$SCRATCH/cpu-v1") == 1 ]]
    [[ $(cpu_level "$SCRATCH/cpu-v2") == 2 ]]
    [[ $(cpu_level "$SCRATCH/cpu-v3") == 3 ]]
    cat "$SCRATCH/cpu-v2" "$SCRATCH/cpu-v3" > "$SCRATCH/cpu-mixed"
    [[ $(cpu_level "$SCRATCH/cpu-mixed") == 2 ]]
    grep -v nonexistent "$SCRATCH/cpu-v3" | sed 's/ avx / /' > "$SCRATCH/cpu-no-avx"
    [[ $(cpu_level "$SCRATCH/cpu-no-avx") == 2 ]]
)
pass 'CPU v1/v2/v3, mixed vCPU, and missing AVX cases'

if compgen -G '/boot/vmlinuz-*xanmod*' >/dev/null; then
    (
        # shellcheck disable=SC1090
        source "$SCRIPT"
        # Used by sourced production functions below.
        # shellcheck disable=SC2034
        STATE="$SCRATCH/grub-state"
        init_state
        PACKAGE=$(dpkg-query -W -f='${binary:Package}\n' 'linux-xanmod-lts-*' | head -n 1)
        KERNEL_RELEASE=$(dpkg-query -W -f='${Depends}\n' "$PACKAGE" | tr ',' '\n' | awk '/linux-image-/ {sub(/^linux-image-/,"",$1); print $1; exit}')
        mkdir -p /boot/grub
        # Fixture follows IDs emitted by Debian's installed /etc/grub.d/10_linux.
        printf "submenu 'Advanced options for Debian' \$menuentry_id_option 'gnulinux-advanced-test-uuid' {\nmenuentry 'Debian XanMod' \$menuentry_id_option 'gnulinux-%s-advanced-test-uuid' {\n}\n}\n" "$KERNEL_RELEASE" > /boot/grub/grub.cfg
        # shellcheck disable=SC2317
        update-grub() { :; } # Fixture only: Docker cannot probe a real boot disk.
        configure_grub
        sh -n /etc/default/grub.d/90-singbox-tune.cfg
        # shellcheck disable=SC1091
        . /etc/default/grub.d/90-singbox-tune.cfg
        [[ $GRUB_DEFAULT == "gnulinux-advanced-test-uuid>gnulinux-$KERNEL_RELEASE-advanced-test-uuid" ]]
        # Verify that future metapackage updates change the selected kernel.
        printf x > /boot/vmlinuz-99.1-x64v3-xanmod1
        # shellcheck disable=SC2317
        dpkg-query() { printf 'linux-image-99.1-x64v3-xanmod1, linux-headers-99.1-x64v3-xanmod1\n'; }
        # shellcheck disable=SC1091
        . /etc/default/grub.d/90-singbox-tune.cfg
        [[ $GRUB_DEFAULT == 'gnulinux-advanced-test-uuid>gnulinux-99.1-x64v3-xanmod1-advanced-test-uuid' ]]
        rm /boot/vmlinuz-99.1-x64v3-xanmod1
        # shellcheck disable=SC2034
        TEST=1
        rollback
    )
    pass 'GRUB menu IDs and following future metapackage (fixture; not boot test)'
fi
printf 'INTEGRATION RESULT: %s groups passed; Debian %s; kernel=%s\n' "$passed" "$(. /etc/os-release; echo "$VERSION_ID")" "$(uname -r)"
