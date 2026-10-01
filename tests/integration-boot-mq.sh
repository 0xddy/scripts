#!/usr/bin/env bash
# Docker --network none --cap-add NET_ADMIN only; no host sysctls or modules
# are modified. This test uses REAL ifb/mq/fq/HTB queues with one documented
# adapter: global default_qdisc cannot be set inside the test netns, so explicit
# mq/fq handles are displayed as native zero handles, and root deletion rebuilds
# that real mq/fq tree. Native handle-zero/default-fq creation is simulated;
# queue transitions, service helper execution, rollback and rejection are real.
# VPS_TUNE_BOOT_MQ_TEST=1 bash tests/integration-boot-mq.sh [main-script]
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
if [[ ${VPS_TUNE_BOOT_MQ_TEST:-0} != 1 || ! -f /.dockerenv ]]; then
    printf 'SKIP: explicitly opt in inside Docker --network none --cap-add NET_ADMIN.\n'
    exit 0
fi
((EUID == 0)) || exit 1
[[ -z $(ip -4 route show default) && -z $(ip -6 route show default) ]] || {
    printf 'Use --network none; existing default route refused.\n' >&2; exit 1;
}
SCRIPT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/vps-tune.sh}
# shellcheck source=/dev/null
source "$SCRIPT"
trap - EXIT ERR INT TERM
for file in /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service; do
    [[ ! -e $file && ! -L $file ]] || { printf 'Refusing existing file: %s\n' "$file" >&2; exit 1; }
done
MQ_LAB=$(mktemp -d /tmp/vps-boot-mq-integration.XXXXXXXX)
REAL_TC=$(command -v tc)
STATE=$MQ_LAB/state
TMP=$MQ_LAB/tmp
mkdir -p "$TMP"
export MQ_LAB REAL_TC
finish_mq_test() {
    local rc=$?
    trap - EXIT
    ip link del bootmq0 2>/dev/null || true
    rm -f -- /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service
    if ((rc)); then printf 'Preserved boot-mq diagnostics: %s\n' "$MQ_LAB" >&2
    else rm -rf -- "$MQ_LAB"; fi
    exit "$rc"
}
trap finish_mq_test EXIT

rebuild_test_mq() {
    local index
    "$REAL_TC" qdisc replace dev bootmq0 root handle 7b00: mq || return 1
    for index in 1 2 3 4; do
        "$REAL_TC" qdisc replace dev bootmq0 parent "7b00:$index" handle "7b1$index:" fq || return 1
    done
}
tc() {
    local result
    if [[ $* == 'filter show dev bootmq0 parent :2' && -f $MQ_LAB/leaf-filter ]]; then
        printf 'filter protocol ip pref 1 u32 chain 0\n'; return 0
    fi
    if [[ $1 == filter && $2 == show ]]; then "$REAL_TC" "$@"; return; fi
    if [[ ( $1 == qdisc || $1 == class ) && $2 == show ]]; then
        result=$("$REAL_TC" "$@") || return 1
        if [[ -f $MQ_LAB/raw-handles ]]; then printf '%s\n' "$result"
        else
            sed -E 's/^qdisc mq 7b00:/qdisc mq 0:/; s/^qdisc fq 7b1[1-4]:/qdisc fq 0:/; s/ parent 7b00:/ parent :/g; s/^class mq 7b00:/class mq :/' <<< "$result"
        fi
        return
    fi
    printf '%s\n' "$*" >> "$MQ_LAB/mutations"
    if [[ $* == 'class replace dev bootmq0 parent 7a10: classid 7a10:1 '* && -f $MQ_LAB/fail-class ]]; then
        rm "$MQ_LAB/fail-class"; return 1
    fi
    "$REAL_TC" "$@" || return 1
    if [[ $* == 'qdisc del dev bootmq0 root' ]]; then rebuild_test_mq; fi
}
sysctl() {
    [[ $* == '-n net.core.default_qdisc' ]] || { printf 'Unexpected sysctl access: %s\n' "$*" >&2; return 1; }
    printf 'fq\n'
}
modprobe() { [[ $1 == sch_htb || $1 == sch_fq ]]; }
# The production-generated helper starts a fresh Bash and resets PATH. Export
# only these test adapters so its own emitted dependencies must be complete.
export -f rebuild_test_mq tc sysctl modprobe

ip link add bootmq0 numtxqueues 4 type ifb
ip link set bootmq0 up
init_state
"$REAL_TC" qdisc replace dev bootmq0 root handle 7a00: fq
shape_mark_fq bootmq0
shape_capture_boot_mq bootmq0
[[ -s $STATE/shaping/boot-mq.bootmq0 ]]
boot_signature=$(shape_signature bootmq0)
shape_boot_mq_matches bootmq0 "$boot_signature"
shape_mq_filter_guard bootmq0 "$boot_signature"
SHAPE_IFACE=bootmq0
SHAPE_RATE=1037
printf 'bootmq0 1037\n' > "$STATE/shaping/active"
shape_write_service

# Execute the actual generated launcher in a fresh process, exercising emitted
# mq validators, ownership checks, runtime activation and service traps.
bash /usr/local/sbin/vps-tune-shape > "$MQ_LAB/start.log" 2>&1
shape_verify_rate bootmq0 1037
[[ $(shape_signature bootmq0) == "$(cat "$STATE/shaping/active.signature")" ]]
printf 'PASS generated helper: captured boot mq/fq becomes HTB 1037 Mbit/s.\n'

rebuild_test_mq
touch "$MQ_LAB/fail-class"
if bash /usr/local/sbin/vps-tune-shape > "$MQ_LAB/failure.log" 2>&1; then
    printf 'Injected class creation failure was ignored.\n' >&2; exit 1
fi
[[ ! -e $MQ_LAB/fail-class && $(shape_signature bootmq0) == "$boot_signature" ]]
printf 'PASS generated helper: interrupted HTB creation restores identical boot mq/fq.\n'

cp "$MQ_LAB/mutations" "$MQ_LAB/before-rejection"
touch "$MQ_LAB/leaf-filter"
if bash /usr/local/sbin/vps-tune-shape > "$MQ_LAB/filter.log" 2>&1; then
    printf 'Injected leaf filter was accepted.\n' >&2; exit 1
fi
rm "$MQ_LAB/leaf-filter"
cmp "$MQ_LAB/before-rejection" "$MQ_LAB/mutations"
[[ $(shape_signature bootmq0) == "$boot_signature" ]]
printf 'PASS generated helper: leaf filter blocks all queue mutations.\n'

# The same real queue with its true, explicit nonzero handles is unsupported.
# Turn off only display adaptation to prove the strict guard rejects it.
touch "$MQ_LAB/raw-handles"
actual_before=$(shape_signature bootmq0)
if bash /usr/local/sbin/vps-tune-shape > "$MQ_LAB/unsupported.log" 2>&1; then
    printf 'Uncaptured explicit mq handles were accepted.\n' >&2; exit 1
fi
[[ $(shape_signature bootmq0) == "$actual_before" ]]
cmp "$MQ_LAB/before-rejection" "$MQ_LAB/mutations"
rm "$MQ_LAB/raw-handles"
printf 'PASS real unsupported mq layout: rejected without queue mutations.\n'
printf 'PASS boot-mq integration (native default/zero-handle presentation simulated as documented).\n'
