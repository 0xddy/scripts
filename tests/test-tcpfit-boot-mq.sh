#!/usr/bin/env bash
# Native multiqueue boot restoration tests. Every tc/sysctl/module operation is
# modeled with files under a private temporary directory; no networking occurs.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
HARNESS_PATH=$PATH
if [[ ${1:-} == --case ]]; then
    MODE=case; CASE=$2; SCRIPT=$3
else
    MODE=all
    target=${1:-${TARGET_SCRIPT:-$(dirname "$SELF")/../vps-tune.sh}}
    SCRIPT=$(cd "$(dirname "$target")" && pwd)/$(basename "$target")
fi
HARNESS_TMP=$(mktemp -d)
HARNESS_OWNER_PID=$BASHPID
trap 'if [[ $BASHPID == "$HARNESS_OWNER_PID" ]]; then rm -rf -- "$HARNESS_TMP"; fi' EXIT

load_script() {
    # shellcheck source=/dev/null
    source "$SCRIPT"
    PATH=$HARNESS_PATH
    trap - ERR INT TERM
    trap 'if [[ $BASHPID == "$HARNESS_OWNER_PID" ]]; then rm -rf -- "$HARNESS_TMP"; fi' EXIT
}

assert_eq() { [[ $1 == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }; }

setup_mq() {
    load_script
    STATE="$HARNESS_TMP/state"
    mkdir -p "$STATE/shaping"
    MQ_SIGNATURE=$'qdisc mq 0: root\nqdisc fq 0: parent :1 limit 10000p\nqdisc fq 0: parent :2 limit 10000p\nclass mq :1 root\nclass mq :2 root'
    FQ_SIGNATURE='qdisc fq 7a00: root limit 10000p'
    HTB_SIGNATURE=$'qdisc htb 7a10: root default 0x1\nqdisc fq 7a11: parent 7a10:1 maxrate 1037Mbit\nclass htb 7a10:1 root rate 1037Mbit ceil 1037Mbit'
    NATIVE_SIGNATURE=$MQ_SIGNATURE
    QUEUE_FILE="$HARNESS_TMP/current-queue"
    EVENTS="$HARNESS_TMP/events"
    printf '%s\n' "$MQ_SIGNATURE" > "$QUEUE_FILE"
    printf '%s\n' "$MQ_SIGNATURE" > "$STATE/shaping/boot-mq.test0"
    printf '%s\n' "$FQ_SIGNATURE" > "$STATE/shaping/fq.test0"
    printf '%s\n' "$HTB_SIGNATURE" > "$STATE/shaping/active.signature"
    printf 'test0 1037\n' > "$STATE/shaping/active"
    : > "$EVENTS"
    DEFAULT_QDISC=fq; FILTER_PARENT=''; VERIFY_RC=0; APPLY_RC=0
    SHAPE_IFACE=test0; SHAPE_RATE=1037
    shape_signature() { assert_eq "$1" test0; cat "$QUEUE_FILE"; }
    sysctl() {
        case $* in
            '-n net.core.default_qdisc') printf '%s\n' "$DEFAULT_QDISC" ;;
            '-w net.core.default_qdisc=fq') DEFAULT_QDISC=fq ;;
            *) return 92 ;;
        esac
    }
    modprobe() { :; }
    tc() {
        case $* in
            'qdisc show dev test0') sed -n '/^qdisc /p' "$QUEUE_FILE" ;;
            'class show dev test0') sed -n '/^class /p' "$QUEUE_FILE" ;;
            'filter show dev test0') [[ $FILTER_PARENT != global ]] || printf 'filter protocol all pref 1 u32\n' ;;
            'filter show dev test0 root') [[ $FILTER_PARENT != root ]] || printf 'filter protocol all pref 1 u32\n' ;;
            'filter show dev test0 parent '*)
                [[ -z $FILTER_PARENT || ${*: -1} != "$FILTER_PARENT" ]] || printf 'filter protocol all pref 1 u32\n' ;;
            'qdisc replace dev test0 root handle 7a01: fq')
                printf 'temporary-fq\n' >> "$EVENTS"
                printf 'qdisc fq 7a01: root limit 10000p\n' > "$QUEUE_FILE" ;;
            'qdisc replace dev test0 root handle 7a00: fq')
                printf 'owned-fq\n' >> "$EVENTS"
                printf '%s\n' "$FQ_SIGNATURE" > "$QUEUE_FILE" ;;
            'qdisc del dev test0 root')
                printf 'restore-native\n' >> "$EVENTS"
                printf '%s\n' "$NATIVE_SIGNATURE" > "$QUEUE_FILE" ;;
            *) printf 'Unexpected tc command: %s\n' "$*" >&2; return 92 ;;
        esac
        return 0
    }
    shape_put_rate() {
        assert_eq "$1 $2" 'test0 1037'
        printf 'apply-rate:1037\n' >> "$EVENTS"
        printf '%s\n' "$HTB_SIGNATURE" > "$QUEUE_FILE"
        return "$APPLY_RC"
    }
    shape_verify_rate() { assert_eq "$1 $2" 'test0 1037'; return "$VERIFY_RC"; }
}

test_exact_marker_and_default() {
    setup_mq
    shape_boot_mq_matches test0 "$MQ_SIGNATURE"
    if shape_boot_mq_matches test0 "${MQ_SIGNATURE/limit 10000p/limit 9999p}"; then return 1; fi
    DEFAULT_QDISC=fq_codel
    if shape_boot_mq_matches test0 "$MQ_SIGNATURE"; then return 1; fi
    DEFAULT_QDISC=fq
    rm -- "$STATE/shaping/boot-mq.test0"
    if shape_boot_mq_matches test0 "$MQ_SIGNATURE"; then return 1; fi
    [[ ! -s $EVENTS ]]
}

test_leaf_filter_guard() {
    setup_mq
    shape_filter_guard test0
    FILTER_PARENT=:2
    if shape_filter_guard test0; then printf 'Leaf filter escaped the boot guard\n' >&2; return 1; fi
    FILTER_PARENT=global
    if shape_filter_guard test0; then printf 'Unclassified filter escaped the boot guard\n' >&2; return 1; fi
    [[ ! -s $EVENTS ]]
}

test_capture_observes_native_mq() {
    setup_mq
    printf '%s\n' "$HTB_SIGNATURE" > "$QUEUE_FILE"
    shape_capture_boot_mq test0
    assert_eq "$(cat "$STATE/shaping/boot-mq.test0")" "$MQ_SIGNATURE"
    assert_eq "$(cat "$QUEUE_FILE")" "$MQ_SIGNATURE"
    assert_eq "$(cat "$EVENTS")" $'temporary-fq\nrestore-native'
}

test_capture_without_native_mq_forgets_old_marker() {
    setup_mq
    NATIVE_SIGNATURE='qdisc fq 0: root limit 10000p'
    shape_capture_boot_mq test0
    [[ ! -e $STATE/shaping/boot-mq.test0 ]]
    assert_eq "$(cat "$QUEUE_FILE")" "$NATIVE_SIGNATURE"
}

test_owned_queue_accepts_recorded_native_state() {
    setup_mq
    shape_require_owned test0
    printf '%s\n' "${MQ_SIGNATURE/limit 10000p/limit 9999p}" > "$QUEUE_FILE"
    (shape_require_owned test0) &
    local child=$!
    if wait "$child"; then printf 'Modified native MQ accepted as owned\n' >&2; return 1; fi
    [[ ! -s $EVENTS ]]
}

test_boot_installs_existing_rate_and_is_repeatable() {
    setup_mq
    (shape_service_start)
    assert_eq "$(cat "$QUEUE_FILE")" "$HTB_SIGNATURE"
    assert_eq "$(cat "$STATE/shaping/active.signature")" "$HTB_SIGNATURE"
    assert_eq "$(cat "$STATE/shaping/boot-mq.test0")" "$MQ_SIGNATURE"
    (shape_service_start)
    assert_eq "$(cat "$QUEUE_FILE")" "$HTB_SIGNATURE"
    assert_eq "$(cat "$EVENTS")" $'apply-rate:1037\napply-rate:1037'
}

test_boot_rejects_changes_without_mutation() {
    local fixture
    for fixture in signature default filter; do
        (
            setup_mq
            case $fixture in
                signature) printf '%s\n' "${MQ_SIGNATURE/limit 10000p/limit 9999p}" > "$QUEUE_FILE" ;;
                default) DEFAULT_QDISC=cake ;;
                filter) FILTER_PARENT=:1 ;;
            esac
            local before
            before=$(cat "$QUEUE_FILE")
            (shape_service_start) &
            local child=$!
            if wait "$child"; then printf 'Boot accepted changed %s\n' "$fixture" >&2; return 1; fi
            assert_eq "$(cat "$QUEUE_FILE")" "$before"
            [[ ! -s $EVENTS ]]
        )
    done
}

test_boot_failure_restores_native_mq() {
    local fixture
    for fixture in apply verify; do
        (
            setup_mq
            if [[ $fixture == apply ]]; then APPLY_RC=1; else VERIFY_RC=1; fi
            (shape_service_start) &
            local child=$!
            if wait "$child"; then printf 'Boot %s failure accepted\n' "$fixture" >&2; return 1; fi
            assert_eq "$(cat "$QUEUE_FILE")" "$MQ_SIGNATURE"
            assert_eq "$(cat "$EVENTS")" $'apply-rate:1037\nrestore-native'
            assert_eq "$(cat "$STATE/shaping/active.signature")" "$HTB_SIGNATURE"
        )
    done
}

test_sweep_restores_recorded_mq() {
    setup_mq
    SHAPE_BEFORE_SIGNATURE=$MQ_SIGNATURE; SHAPE_BEFORE_RATE=''
    printf '%s\n' "$HTB_SIGNATURE" > "$QUEUE_FILE"
    shape_restore_original
    assert_eq "$(cat "$QUEUE_FILE")" "$MQ_SIGNATURE"
    assert_eq "$(cat "$EVENTS")" restore-native
}

test_migration_abort_restores_previous_marker() {
    local fixture
    for fixture in absent present; do
        (
            setup_mq
            local original="$STATE/tcpfit-migration/original" old_marker
            old_marker=${MQ_SIGNATURE/limit 10000p/limit 9000p}
            mkdir -p "$original"
            printf 'test0\n' > "$original/iface"
            printf '0\n' > "$original/vps-enabled"
            rm -f -- "$original/vps-boot-mq"
            if [[ $fixture == present ]]; then printf '%s\n' "$old_marker" > "$original/vps-boot-mq"; fi
            tcpfit_backup_verify() { :; }
            tcpfit_restore_original() { :; }
            shape_restore_persistence() { :; }
            systemctl() { :; }
            tcpfit_migration_abort
            assert_eq "$(tcpfit_migration_state)" restored
            if [[ $fixture == present ]]; then assert_eq "$(cat "$STATE/shaping/boot-mq.test0")" "$old_marker"
            else [[ ! -e $STATE/shaping/boot-mq.test0 ]]; fi
        )
    done
}

if [[ $MODE == case ]]; then "$CASE"; exit; fi
passed=0
failed=0
case_run() {
    local label=$1 fn=$2
    if bash "$SELF" --case "$fn" "$SCRIPT" > "$HARNESS_TMP/case.log" 2>&1; then
        printf 'PASS %s\n' "$label"; passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$label"; cat "$HARNESS_TMP/case.log"; failed=$((failed+1))
    fi
}

case_run 'Native MQ matches only its exact marker with fq default' test_exact_marker_and_default
case_run 'Filters attached to MQ leaves prevent takeover' test_leaf_filter_guard
case_run 'Migration observes and records the actual native MQ tree' test_capture_observes_native_mq
case_run 'Single-queue native state removes stale MQ markers' test_capture_without_native_mq_forgets_old_marker
case_run 'Ownership accepts recorded boot MQ and rejects changed parameters' test_owned_queue_accepts_recorded_native_state
case_run 'Boot restores the existing HTB rate and is repeatable' test_boot_installs_existing_rate_and_is_repeatable
case_run 'Boot rejects signature, default and filter changes before mutation' test_boot_rejects_changes_without_mutation
case_run 'Failed boot apply or verification restores exact native MQ' test_boot_failure_restores_native_mq
case_run 'Sweep restoration can return to the recorded native MQ state' test_sweep_restores_recorded_mq
case_run 'Aborted migration restores an older marker or its original absence' test_migration_abort_restores_previous_marker
printf '\nTcpfit boot MQ: %s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
