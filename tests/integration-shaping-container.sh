#!/usr/bin/env bash
# Run only in disposable Docker with --network none --cap-add NET_ADMIN.
# Tests real tc in its own network namespace; no public traffic or modprobe.
# Sourced code consumes these globals and mocks.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Disposable Docker container required' >&2; exit 1; }
SCRIPT=${1:?script path required}
# shellcheck source=/dev/null
source "$SCRIPT"
trap - EXIT ERR INT TERM
STATE=$(mktemp -d)
trap 'rm -rf -- "$STATE"' EXIT
ip link add test0 type dummy
ip link set test0 up
ip addr add 192.0.2.2/24 dev test0
ip route add default via 192.0.2.1 dev test0
shape_put_fq test0
shape_mark_fq test0
shape_require_owned test0
shape_put_fq test0
SHAPE_IFACE=test0
SHAPE_BEFORE_RATE=
SHAPE_BEFORE_SIGNATURE=$(shape_signature test0)
for rate in 1 530 1000 10000; do
    shape_put_rate test0 "$rate"
    shape_verify_rate test0 "$rate"
    shape_restore_original
    [[ $(shape_signature test0) == "$SHAPE_BEFORE_SIGNATURE" ]]
done
# A real externally changed fq option must invalidate ownership.
tc qdisc change dev test0 root handle 7a00: fq limit 9999
if (shape_require_owned test0); then echo 'Ownership accepted changed fq parameters' >&2; exit 1; fi
# Explicit queue fq must rebuild default parameters before recording ownership.
modprobe() { :; }
sysctl() { [[ $1 != -n ]] || printf 'fq\n'; }
QDISC=fq
SYSCTL="$STATE/test-sysctl.conf"
switch_queue
[[ $(shape_signature test0) == "$SHAPE_BEFORE_SIGNATURE" ]]
shape_require_owned test0
SHAPE_BEFORE_RATE=530
shape_put_rate test0 530
SHAPE_BEFORE_SIGNATURE=$(shape_signature test0)
shape_put_rate test0 490
shape_restore_original
shape_verify_rate test0 530
[[ $(shape_signature test0) == "$SHAPE_BEFORE_SIGNATURE" ]]
shape_put_fq test0
shape_mark_fq test0
preflight() { :; }
# Real queue and persistence transactions, isolated from systemd on the host.
systemctl() {
    if [[ -f $STATE/fail-service && $1 == "$(cat "$STATE/fail-service")" ]]; then
        rm "$STATE/fail-service"
        return 1
    fi
    case $1 in
        is-enabled) [[ -f $STATE/service-enabled ]] ;;
        enable) touch "$STATE/service-enabled" ;;
        disable) rm -f "$STATE/service-enabled" ;;
        *) return 0 ;;
    esac
}
expect_action_failure() {
    # Background execution preserves errexit inside the real action, while
    # testing its nonzero status via wait does not suppress those semantics.
    (set -e; run_shape_action) &
    local pid=$!
    if wait "$pid"; then echo 'Expected transaction failure did not occur' >&2; exit 1; fi
}
ACTION=shape; SHAPE_RATE=530; SHAPE_OFF=0
DRY=1
before_dry=$(shape_signature test0)
run_shape_action
[[ $(shape_signature test0) == "$before_dry" && ! -f $STATE/shaping/active ]]
DRY=0
run_shape_action
shape_verify_rate test0 530
[[ $(cat "$STATE/shaping/active") == 'test0 530' ]]
before_failure=$(shape_signature test0)
helper_hash=$(sha256sum /usr/local/sbin/vps-tune-shape)
printf 'daemon-reload\n' > "$STATE/fail-service"
SHAPE_RATE=700
expect_action_failure
[[ $(shape_signature test0) == "$before_failure" ]]
[[ $(sha256sum /usr/local/sbin/vps-tune-shape) == "$helper_hash" ]]
[[ $(cat "$STATE/shaping/active") == 'test0 530' && -f $STATE/service-enabled ]]
SHAPE_OFF=1; SHAPE_RATE=
printf 'disable\n' > "$STATE/fail-service"
expect_action_failure
[[ $(shape_signature test0) == "$before_failure" ]]
[[ $(cat "$STATE/shaping/active") == 'test0 530' && -f $STATE/service-enabled ]]
run_shape_action
[[ $(shape_signature test0) == "$(cat "$STATE/shaping/fq.test0")" ]]
[[ ! -f $STATE/shaping/active && ! -f $STATE/service-enabled ]]
printf 'PASS real isolated queue rebuild, fq/HTB rates, restoration, and service-failure transactions\n'
