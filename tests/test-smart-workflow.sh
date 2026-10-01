#!/usr/bin/env bash
# Integrated smart tuning regression tests. No host sysctls, queues or network
# traffic are touched: all external actions are mocked, including menu actions.
# Usage: bash tests/test-smart-workflow.sh [path/to/vps-tune.sh]
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
HARNESS_PATH=$PATH
if [[ ${1:-} == --case || ${1:-} == --probe ]]; then
    MODE=$1; CASE=$2; SCRIPT=$3; shift 3
else
    MODE=all
    target=${1:-${TARGET_SCRIPT:-$(dirname "$SELF")/../vps-tune.sh}}
    SCRIPT=$(cd "$(dirname "$target")" && pwd)/$(basename "$target")
fi
HARNESS_TMP=${SMART_TEST_DIR:-$(mktemp -d)}
HARNESS_OWNER_PID=$BASHPID
trap 'if [[ -z ${SMART_TEST_DIR:-} && $BASHPID == "$HARNESS_OWNER_PID" ]]; then rm -rf -- "$HARNESS_TMP"; fi' EXIT

load_script() {
    # shellcheck source=/dev/null
    source "$SCRIPT"
    PATH=$HARNESS_PATH
    trap - ERR INT TERM
    trap 'if [[ -z ${SMART_TEST_DIR:-} && $BASHPID == "$HARNESS_OWNER_PID" ]]; then rm -rf -- "$HARNESS_TMP"; fi' EXIT
}

assert_eq() {
    [[ $1 == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }
}

parse_ok() { (load_script; parse_args "$@"); }
parse_bad() {
    if (load_script; parse_args "$@"); then
        printf 'Unexpectedly accepted: %s\n' "$*" >&2
        return 1
    fi
}

smart_args() {
    SMART_ARGS=(apply --kernel skip --smart-bandwidth --bandwidth-mbps 500
        --rtt-ms 100 --smart-sweep --peer 192.0.2.1 --accept-traffic)
}

test_parser_valid() {
    load_script
    smart_args
    parse_args "${SMART_ARGS[@]}" --apply-suggested-shape
    assert_eq "$SMART $SMART_SWEEP $APPLY_SUGGESTED_SHAPE $QDISC $KERNEL" '1 1 1 fq skip'
    parse_ok "${SMART_ARGS[@]}" --qdisc fq
    parse_ok apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --smart-profile asia-bdp --smart-sweep --peer 192.0.2.1 --accept-traffic
    parse_ok apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --smart-profile tcpfit-bdp --smart-sweep --peer 192.0.2.1 --accept-traffic
    parse_ok apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --smart-profile overseas-bdp --smart-sweep --peer authorized.example --dry-run
    parse_ok apply --kernel skip --smart-bandwidth --speedtest-json fixture.json --rtt-ms 100 --smart-sweep --peer 192.0.2.1 --accept-traffic
    parse_ok sweep --peer 192.0.2.1 --nominal-mbps 500 --accept-traffic
    parse_ok apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100
    load_script
    parse_args apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --smart-profile tcpfit-bdp --dry-run
    assert_eq "$RTT_MS" 150
}

test_parser_rejections() {
    smart_args
    parse_bad "${SMART_ARGS[@]}" --qdisc cake
    parse_bad "${SMART_ARGS[@]}" --qdisc fq_codel
    parse_bad "${SMART_ARGS[@]}" --kernel lts
    parse_bad "${SMART_ARGS[@]}" --kernel main
    parse_bad "${SMART_ARGS[@]}" --container-test
    parse_bad "${SMART_ARGS[@]}" --container-test --dry-run
    parse_bad "${SMART_ARGS[@]}" --smart-profile asia
    parse_bad "${SMART_ARGS[@]}" --smart-profile overseas
    parse_bad "${SMART_ARGS[@]}" --rate-mbps 530
    parse_bad "${SMART_ARGS[@]}" --off
    parse_bad "${SMART_ARGS[@]}" --nominal-mbps 500
    parse_bad "${SMART_ARGS[@]}" --peer 'host;id'
    parse_bad "${SMART_ARGS[@]}" --peer -bad
    parse_bad apply --kernel skip --smart-sweep --peer 192.0.2.1 --accept-traffic
    parse_bad apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --smart-sweep --accept-traffic
    parse_bad apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --smart-sweep --peer 192.0.2.1
    parse_bad apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --apply-suggested-shape
    parse_bad sweep --peer 192.0.2.1 --nominal-mbps 500 --accept-traffic --apply-suggested-shape
    parse_bad check --smart-sweep --peer 192.0.2.1 --accept-traffic
}

test_nominal() {
    load_script
    SMART_SWEEP=1
    local value expected
    for value in 0.001 0.49 0.5 1 499.49 499.5 10000; do
        case $value in 0.*|1) expected=1 ;; 499.49) expected=499 ;; 499.5) expected=500 ;; 10000) expected=10000 ;; esac
        BANDWIDTH=$value
        smart_sweep_nominal
        assert_eq "$SWEEP_NOMINAL" "$expected"
    done
    BANDWIDTH=10001
    if (smart_sweep_nominal); then printf 'Out-of-budget nominal accepted\n' >&2; return 1; fi
}

setup_preflight() {
    load_script
    STATE="$HARNESS_TMP/preflight-state"
    mkdir -p "$STATE/shaping"
    rm -f -- "$STATE/shaping/active" "$STATE/shaping/active.signature" "$STATE/shaping/fq.test0"
    SMART_SWEEP=1; SMART_SWEEP_REUSE_QUEUE=0; SWEEP_PEER=192.0.2.1
    DEFAULT_ROUTES='default via 192.0.2.254 dev test0'
    PEER_IFACE=test0
    QUEUE='qdisc fq_codel 0: root refcnt 2 limit 10240p'
    CLASSES=''; FILTERS=''; AVAILABLE='reno cubic bbr'; MODULE_OK=0
    sysctl() {
        case $* in
            '-n net.ipv4.tcp_available_congestion_control') printf '%s\n' "$AVAILABLE" ;;
            '-n net.core.default_qdisc') printf 'fq\n' ;;
            *) return 95 ;;
        esac
    }
    ip() {
        case $* in
            '-o -4 route show default') printf '%s\n' "$DEFAULT_ROUTES" ;;
            '-o -6 route show default') : ;;
            'route get 192.0.2.1') printf '192.0.2.1 dev %s src 192.0.2.2\n' "$PEER_IFACE" ;;
            *) return 95 ;;
        esac
    }
    tc() {
        case $* in
            'qdisc show dev test0') printf '%s\n' "$QUEUE" ;;
            'class show dev test0') printf '%s' "$CLASSES" ;;
            'filter show dev test0 '*) printf '%s' "$FILTERS" ;;
            *) return 95 ;;
        esac
    }
    getent() { printf '192.0.2.1 STREAM peer\n'; }
    modprobe() { return 95; }
    modinfo() { return "$MODULE_OK"; }
    jq() { return 95; }
    iperf3() { return 95; }
    timeout() { return 95; }
    shape_owned_files_guard() { :; }
}

test_preflight_simple_and_owned() {
    setup_preflight
    smart_sweep_preflight
    assert_eq "$SMART_SWEEP_IFACE $SMART_SWEEP_REUSE_QUEUE" 'test0 0'
    AVAILABLE='reno cubic'; MODULE_OK=0
    smart_sweep_preflight
    QUEUE='qdisc fq 7a00: root refcnt 2 limit 10000p'
    shape_signature test0 > "$STATE/shaping/fq.test0"
    smart_sweep_preflight
    assert_eq "$SMART_SWEEP_REUSE_QUEUE" 1
    printf 'test0 514\n' > "$STATE/shaping/active"
    QUEUE=$'qdisc htb 7a10: root refcnt 2 default 0x1\nqdisc fq 7a20: parent 7a10:1 limit 10000p'
    CLASSES='class htb 7a10:1 root rate 514Mbit ceil 514Mbit'
    shape_signature test0 > "$STATE/shaping/active.signature"
    smart_sweep_preflight
    assert_eq "$SMART_SWEEP_IFACE $SMART_SWEEP_REUSE_QUEUE" 'test0 1'
}

test_preflight_rejections() {
    local fixture
    for fixture in multi-route peer-route mq third-party-htb extra-hook classes cake-cap filter no-bbr changed-owned; do
        setup_preflight
        case $fixture in
            multi-route) DEFAULT_ROUTES+=$'\ndefault via 198.51.100.254 dev other0' ;;
            peer-route) PEER_IFACE=other0 ;;
            mq) QUEUE='qdisc mq 0: root' ;;
            third-party-htb) QUEUE='qdisc htb 1: root default 1' ;;
            extra-hook) QUEUE+=$'\nqdisc clsact ffff: parent ffff:fff1' ;;
            classes) CLASSES='class htb 1:1 root rate 100Mbit' ;;
            cake-cap) QUEUE='qdisc cake 0: root bandwidth 100Mbit' ;;
            filter) FILTERS='filter protocol all pref 1 u32' ;;
            no-bbr) AVAILABLE='reno cubic'; MODULE_OK=1 ;;
            changed-owned) printf 'qdisc fq 7a00: root limit 10000p\n' > "$STATE/shaping/fq.test0" ;;
        esac
        if (smart_sweep_preflight); then printf 'Unsafe preflight accepted: %s\n' "$fixture" >&2; return 1; fi
    done
    setup_preflight
    if (
        command() { [[ $* != '-v iperf3' ]] || return 1; builtin command "$@"; }
        smart_sweep_preflight
    ); then printf 'Missing iperf3 dependency accepted\n' >&2; return 1; fi
}

setup_finish() {
    load_script
    STATE="$HARNESS_TMP/state"
    TMP="$HARNESS_TMP/tmp"
    mkdir -p "$STATE/sweeps/20991231-old" "$TMP"
    # A previous validated scan must never authorize the current run's cap.
    printf 'status=validated-suggestion\nrate_mbps=999\n' > "$STATE/sweeps/20991231-old/result.txt"
    EVENTS="$HARNESS_TMP/events"
    : > "$EVENTS"
    SMART=1; SMART_SWEEP=1; SMART_SWEEP_IFACE=test0
    SMART_SWEEP_REUSE_QUEUE=0; SMART_BASE_APPLIED=1
    APPLY_SUGGESTED_SHAPE=1; ACCEPT_TRAFFIC=1; TUNE_LOCK_HELD=1
    QDISC=fq; KERNEL=skip; SWEEP_PEER=192.0.2.1; SWEEP_NOMINAL=500
    TEST=0; DRY=0
    BBR_VALUE=bbr
    sysctl() {
        [[ $* == '-n net.ipv4.tcp_congestion_control' ]] || return 70
        printf '%s\n' "$BBR_VALUE"
    }
    ensure_tmp() { mkdir -p "$TMP"; }
    prepare_scan_tools() { :; }
    persist_scan_tools() { :; }
    activate_persistent_tools() { :; }
    smart_sweep_preflight() { :; }
    switch_queue() {
        [[ $ACTION == queue && $QDISC == fq && $TUNE_LOCK_HELD == 1 ]] || return 71
        printf 'queue\n' >> "$EVENTS"
    }
    run_shape_action() {
        [[ $TUNE_LOCK_HELD == 1 ]] || return 72
        case $ACTION in
            sweep)
                [[ -n $SMART_SWEEP_RESULT_FILE && $SMART_SWEEP_RESULT_FILE != "$STATE"/sweeps/* ]] || return 73
                printf 'sweep\n' >> "$EVENTS"
                case $FIXTURE in
                    valid) printf 'status=validated-suggestion\nrate_mbps=514\n' > "$SMART_SWEEP_RESULT_FILE" ;;
                    low) printf 'status=low-retransmissions\n' > "$SMART_SWEEP_RESULT_FILE" ;;
                    inconclusive) printf 'status=inconclusive-validation\n' > "$SMART_SWEEP_RESULT_FILE" ;;
                    empty) : > "$SMART_SWEEP_RESULT_FILE" ;;
                    missing) rm -f -- "$SMART_SWEEP_RESULT_FILE" ;;
                    invalid-rate) printf 'status=validated-suggestion\nrate_mbps=0\n' > "$SMART_SWEEP_RESULT_FILE" ;;
                    failed) return 7 ;;
                    failed-with-result) printf 'status=validated-suggestion\nrate_mbps=514\n' > "$SMART_SWEEP_RESULT_FILE"; return 7 ;;
                    *) return 74 ;;
                esac ;;
            shape)
                assert_eq "$SHAPE_RATE" 514
                assert_eq "$SHAPE_OFF" 0
                printf 'shape:%s\n' "$SHAPE_RATE" >> "$EVENTS" ;;
            *) return 75 ;;
        esac
    }
}

test_finish_valid() {
    setup_finish
    FIXTURE=valid
    smart_finish_tuning
    assert_eq "$(cat "$EVENTS")" $'queue\nsweep\nshape:514'
    assert_eq "$ACTION" apply
}

test_finish_suggestion_only() {
    setup_finish
    FIXTURE=valid; APPLY_SUGGESTED_SHAPE=0
    smart_finish_tuning
    assert_eq "$(cat "$EVENTS")" $'queue\nsweep'
}

test_finish_no_suggestion() {
    local fixture
    for fixture in low inconclusive empty; do
        setup_finish
        FIXTURE=$fixture
        smart_finish_tuning
        assert_eq "$(cat "$EVENTS")" $'queue\nsweep'
    done
}

test_finish_reuse_queue() {
    setup_finish
    FIXTURE=low; SMART_SWEEP_REUSE_QUEUE=1
    smart_finish_tuning
    assert_eq "$(cat "$EVENTS")" sweep
}

probe_finish() {
    setup_finish
    FIXTURE=$CASE
    if [[ $CASE == bbr-pending ]]; then FIXTURE=valid; BBR_VALUE=cubic; fi
    smart_finish_tuning
}

test_finish_failures() {
    local fixture
    for fixture in failed failed-with-result invalid-rate missing bbr-pending; do
        if SMART_TEST_DIR="$HARNESS_TMP" bash "$SELF" --probe "$fixture" "$SCRIPT"; then
            printf 'Failure fixture succeeded: %s\n' "$fixture" >&2
            return 1
        fi
        if grep -q '^shape:' "$HARNESS_TMP/events"; then printf 'Applied shaping after %s\n' "$fixture" >&2; return 1; fi
        if [[ $fixture == bbr-pending ]]; then assert_eq "$(cat "$HARNESS_TMP/events")" ''; fi
    done
}

test_sweep_reuses_held_lock() {
    load_script
    STATE="$HARNESS_TMP/actual-action"
    mkdir -p "$STATE"
    EVENTS="$STATE/events"
    : > "$EVENTS"
    ACTION=sweep; SWEEP_PEER=192.0.2.1; SWEEP_NOMINAL=500
    TUNE_LOCK_HELD=1; SMART_SWEEP=1; SMART_SWEEP_IFACE=test0
    SMART_SWEEP_RESULT_FILE="$STATE/this-run-result"
    TEST=0; DRY=0
    flock() { printf 'unexpected-flock\n' >> "$EVENTS"; return 90; }
    ip() {
        case $* in
            '-o -4 route show default') printf 'default via 192.0.2.254 dev test0\n' ;;
            '-o -6 route show default') : ;;
            'route get 192.0.2.1') printf '192.0.2.1 dev test0 src 192.0.2.2\n' ;;
            *) return 91 ;;
        esac
    }
    tc() { return 92; }
    iperf3() { return 92; }
    jq() { return 92; }
    timeout() { return 92; }
    getent() { printf '192.0.2.1 STREAM peer\n'; }
    preflight() { :; }
    init_state() { :; }
    shape_read_active() { SHAPE_ACTIVE_IFACE=; SHAPE_ACTIVE_RATE=; }
    persist_scan_tools() { :; }
    shape_require_owned() { :; }
    shape_owned_files_guard() { :; }
    shape_signature() { printf 'qdisc fq 7a00: root limit 10000p\n'; }
    shape_restore_original() { printf 'restore\n' >> "$EVENTS"; }
    shape_run_sweep() {
        SHAPE_LOG_DIR="$STATE/log"
        mkdir -p "$SHAPE_LOG_DIR"
        printf 'status=low-retransmissions\n' > "$SHAPE_LOG_DIR/result.txt"
        printf 'sweep\n' >> "$EVENTS"
    }
    run_shape_action
    assert_eq "$(cat "$EVENTS")" $'sweep\nrestore'
    assert_eq "$(cat "$SMART_SWEEP_RESULT_FILE")" 'status=low-retransmissions'
}

setup_main() {
    setup_finish
    smart_args
    FIXTURE=valid
    TUNE_LOCK_HELD=0; SMART_BASE_APPLIED=0
    SWEEP_NOMINAL=''
    prepare_scan_tools() { printf 'prepare-tools\n' >> "$EVENTS"; }
    persist_scan_tools() { printf 'persist-tools\n' >> "$EVENTS"; }
    check_os() { VERSION_ID=13; CODENAME=trixie; }
    configured_qdisc() { printf 'cake\n'; }
    is_container() { return 1; }
    preflight() { :; }
    flock() { :; }
    resolve_rtt() { :; }
    resolve_bandwidth() { :; }
    choose_plan() { MEM_MIB=1024; BUFFER=14; }
    show_buffer_notice() { :; }
    show_tuning_plan() { :; }
    buffer_plan_description() { printf 'mocked plan\n'; }
    modprobe() { :; }
    tc() { printf 'UNEXPECTED tc\n' >> "$EVENTS"; return 80; }
    iperf3() { printf 'UNEXPECTED iperf3\n' >> "$EVENTS"; return 80; }
    apt_update() { printf 'UNEXPECTED apt\n' >> "$EVENTS"; return 80; }
    apt_install() { printf 'UNEXPECTED apt\n' >> "$EVENTS"; return 80; }
    init_state() { printf 'init-state\n' >> "$EVENTS"; }
    install_kernel() { printf 'kernel:%s\n' "$KERNEL" >> "$EVENTS"; }
    configure_limits() { printf 'limits\n' >> "$EVENTS"; }
    configure_network() { printf 'network:%s\n' "$QDISC" >> "$EVENTS"; }
    apply_runtime() { printf 'runtime\n' >> "$EVENTS"; }
    show_completion() { printf 'complete\n' >> "$EVENTS"; }
    smart_sweep_preflight() { printf 'scan-preflight\n' >> "$EVENTS"; }
}

test_main_dry() {
    ((EUID == 0)) || { printf 'Full main requires Linux root; covered by container run\n'; return 0; }
    setup_main
    is_container() { return 0; }
    main "${SMART_ARGS[@]}" --apply-suggested-shape --dry-run
    # Preflight may validate read-only inputs, but dry-run must not configure
    # sysctls, queue disciplines, run scans, or install persistent shaping.
    if grep -Ev '^scan-preflight$' "$EVENTS" | grep -q .; then cat "$EVENTS"; return 1; fi
}

test_main_review_cancel() {
    ((EUID == 0)) || { printf 'Full main requires Linux root; covered by container run\n'; return 0; }
    setup_main
    review_tuning_plan() { printf 'review-cancel\n' >> "$EVENTS"; return 1; }
    main "${SMART_ARGS[@]}" --apply-suggested-shape --review
    grep -Fxq 'review-cancel' "$EVENTS"
    if grep -Ev '^(scan-preflight|review-cancel)$' "$EVENTS" | grep -q .; then cat "$EVENTS"; return 1; fi
}

test_main_sequence() {
    ((EUID == 0)) || { printf 'Full main requires Linux root; covered by container run\n'; return 0; }
    setup_main
    main "${SMART_ARGS[@]}" --apply-suggested-shape
    assert_eq "$(cat "$EVENTS")" $'prepare-tools\nscan-preflight\ninit-state\npersist-tools\nkernel:skip\nlimits\nnetwork:fq\nruntime\nscan-preflight\nqueue\nsweep\nshape:514\ncomplete'
}

setup_menu() {
    load_script
    MENU_NOFILE=1048576; MENU_CPU=auto; MENU_DKMS=0
    TEST=0; DRY=0; MENU_CONTAINER=1
    MENU_CAPTURE="$HARNESS_TMP/menu-args"
    MENU_CALLS="$HARNESS_TMP/menu-calls"
    : > "$MENU_CAPTURE"; : > "$MENU_CALLS"
    is_container() { return "$MENU_CONTAINER"; }
    menu_run() { printf '%s\n' "$@" > "$MENU_CAPTURE"; printf 'run\n' >> "$MENU_CALLS"; }
    menu_shape() { printf 'advanced\n' >> "$MENU_CALLS"; }
}

menu_has() { grep -Fxq -- "$1" "$MENU_CAPTURE"; }
menu_lacks() { if menu_has "$1"; then printf 'Unexpected menu option: %s\n' "$1" >&2; return 1; fi; }
menu_parses() {
    local -a captured=()
    mapfile -t captured < "$MENU_CAPTURE"
    parse_ok "${captured[@]}"
}

test_menu_complete() {
    setup_menu
    menu_smart <<< $'1\n5\n2\n500\ny\niperf.example.com\ny\ny'
    assert_eq "$(cat "$MENU_CALLS")" run
    menu_has --smart-bandwidth
    menu_has tcpfit-bdp
    menu_has --smart-sweep
    menu_has --apply-suggested-shape
    menu_has --accept-traffic
    menu_has --qdisc
    menu_has fq
    menu_has iperf.example.com
    menu_lacks --nominal-mbps
    menu_parses
}

test_menu_scan_only() {
    setup_menu
    menu_smart <<< $'1\n5\n2\n500\ny\niperf.example.com\nn\ny'
    menu_has --smart-sweep
    menu_has --accept-traffic
    menu_lacks --apply-suggested-shape
    menu_parses
}

test_menu_skip_scan() {
    local input
    for input in $'1\n5\n2\n500\nn' $'1\n5\n2\n500\ny\niperf.example.com\ny\nn'; do
        setup_menu
        menu_smart <<< "$input"
        assert_eq "$(cat "$MENU_CALLS")" run
        menu_has --smart-bandwidth
        menu_lacks --smart-sweep
        menu_lacks --apply-suggested-shape
        menu_lacks --accept-traffic
        menu_lacks --peer
        menu_parses
    done
}

test_menu_basic_and_legacy() {
    setup_menu
    menu_smart <<< $'2\n1\n2\n500'
    menu_has asia-bdp
    menu_lacks --qdisc
    menu_lacks --smart-sweep
    menu_parses
    setup_menu
    menu_smart <<< $'2\n3\n2\n2\n500'
    menu_has asia
    menu_lacks --smart-sweep
    menu_parses
}

test_menu_cancel_container() {
    setup_menu
    menu_smart <<< 0
    assert_eq "$(cat "$MENU_CALLS")" ''
    setup_menu
    MENU_CONTAINER=0
    menu_smart <<< 1
    assert_eq "$(cat "$MENU_CALLS")" ''
    setup_menu
    TEST=1
    menu_smart <<< $'2\n1\n2\n500'
    menu_has --container-test
    menu_lacks --smart-sweep
    menu_parses
}

test_menu_dry_and_advanced() {
    setup_menu
    DRY=1
    menu_smart <<< $'1\n5\n2\n500\ny\niperf.example.com\ny'
    menu_has --dry-run
    menu_has --smart-sweep
    menu_has --apply-suggested-shape
    menu_lacks --accept-traffic
    menu_parses
    setup_menu
    menu_smart <<< 3
    assert_eq "$(cat "$MENU_CALLS")" advanced
    setup_menu
    DRY=1
    menu_smart <<< 3
    assert_eq "$(cat "$MENU_CALLS")" ''
}

test_real_queue_workflow() {
    # Opt-in only: the caller must give a disposable, network-less container
    # NET_ADMIN, never the host network namespace. JSON comes from fixtures.
    [[ -f /.dockerenv && ${SMART_TEST_REAL_TC:-0} == 1 ]] || return 1
    [[ $(ip -o link show | wc -l) == 1 ]] || { printf 'Use Docker --network none\n' >&2; return 1; }
    load_script
    STATE="$HARNESS_TMP/real-state"
    SYSCTL="$STATE/test-sysctl.conf"
    mkdir -p "$STATE"
    ip link add test0 type dummy
    ip link set test0 up
    ip addr add 192.0.2.2/24 dev test0
    ip route add default via 192.0.2.1 dev test0
    tc qdisc replace dev test0 root fq_codel
    preflight() { :; }
    is_container() { return 1; }
    prepare_scan_tools() { :; }
    modprobe() { :; }
    modinfo() { :; }
    getent() { printf '192.0.2.1 STREAM peer\n'; }
    sleep() { :; }
    jq() { "${JQ_REAL_TEST_BIN:?supply the absolute jq binary path}" "$@"; }
    iperf3() { printf 'Real iperf invocation is forbidden\n' >&2; return 96; }
    sysctl() {
        case $* in
            '-n net.ipv4.tcp_available_congestion_control') printf 'reno cubic bbr\n' ;;
            '-n net.ipv4.tcp_congestion_control') printf 'bbr\n' ;;
            '-n net.core.default_qdisc') printf 'fq\n' ;;
            '-n '*) printf '0\n' ;;
            '-w '*) return 0 ;;
            *) return 96 ;;
        esac
    }
    systemctl() {
        case $1 in
            is-enabled) [[ -f $STATE/service-enabled ]] ;;
            enable) touch "$STATE/service-enabled" ;;
            disable) rm -f -- "$STATE/service-enabled" ;;
            *) return 0 ;;
        esac
    }
    timeout() {
        # Read the real installed class rate, then model a reproducible policer
        # at 530 Mbit/s. No socket is opened, even for the baseline sample.
        local rate
        rate=$(tc class show dev test0 | awk '{for(i=1;i<NF;i++)if($i=="rate") {v=$(i+1);if(v~/Gbit$/)print v*1000;else if(v~/Kbit$/)print v/1000;else print v+0;exit}}')
        awk -v rate="${rate:-0}" -v model="$REAL_MODEL" 'BEGIN {
            goodput=480; ratio=3;
            if(rate>0) {goodput=rate*.98;if(goodput>499)goodput=499;ratio=(rate>530?3:.01)}
            if(model=="low")ratio=.01;
            bytes=600000000;mss=1460;retrans=int(bytes/mss*ratio/100);
            printf "{\"start\":{\"tcp_mss_default\":1460},\"end\":{\"sum_sent\":{\"bytes\":%d,\"retransmits\":%d},\"sum_received\":{\"bits_per_second\":%.0f}}}\n",bytes,retrans,goodput*1000000;
        }'
    }
    local -a args=(apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --smart-profile tcpfit-bdp
        --smart-sweep --peer 192.0.2.1 --accept-traffic --apply-suggested-shape)
    REAL_MODEL=valid
    (main "${args[@]}")
    local iface rate signature identity helper_hash runtime_hash
    read -r iface rate < "$STATE/shaping/active"
    [[ $iface == test0 && $rate -ge 500 && $rate -lt 530 ]]
    shape_verify_rate test0 "$rate"
    signature=$(shape_signature test0)
    identity=$(stat -c '%i:%y' "$SYSCTL")
    helper_hash=$(sha256sum /usr/local/sbin/vps-tune-shape)
    runtime_hash=$(sha256sum "$STATE/runtime.before")
    grep -R -Fq 'status=validated-suggestion' "$STATE/sweeps"
    REAL_MODEL=low
    (main "${args[@]}")
    assert_eq "$(shape_signature test0)" "$signature"
    assert_eq "$(cat "$STATE/shaping/active")" "test0 $rate"
    assert_eq "$(stat -c '%i:%y' "$SYSCTL")" "$identity"
    assert_eq "$(sha256sum /usr/local/sbin/vps-tune-shape)" "$helper_hash"
    assert_eq "$(sha256sum "$STATE/runtime.before")" "$runtime_hash"
    grep -R -Fq 'status=low-retransmissions' "$STATE/sweeps"
    # Explicit off still restores fq and retains all base tuning.
    (ACTION=shape; SHAPE_OFF=1; SHAPE_RATE=; run_shape_action)
    [[ ! -f $STATE/shaping/active && -f $SYSCTL ]]
    assert_eq "$(shape_signature test0)" "$(cat "$STATE/shaping/fq.test0")"
}

if [[ $MODE == --probe ]]; then probe_finish; exit; fi
if [[ $MODE == --case ]]; then "$CASE"; exit; fi

passed=0
failed=0
case_run() {
    local label=$1 fn=$2
    if bash "$SELF" --case "$fn" "$SCRIPT" > "$HARNESS_TMP/case.log" 2>&1; then
        printf 'PASS %s\n' "$label"
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$label"
        cat "$HARNESS_TMP/case.log"
        failed=$((failed+1))
    fi
}

case_run 'Integrated CLI accepts BDP and authorized scan inputs' test_parser_valid
case_run 'Integrated CLI rejects conflicting, unauthorized and container inputs' test_parser_rejections
case_run 'Resolved bandwidth supplies rounded and bounded scan nominal' test_nominal
case_run 'Read-only preflight accepts simple queues and recognizes owned state' test_preflight_simple_and_owned
case_run 'Preflight rejects ambiguous routes, custom queues/filters and unavailable BBR' test_preflight_rejections
case_run 'Validated scan applies only the current recommendation under one lock' test_finish_valid
case_run 'Suggestion-only integrated scan does not apply a cap' test_finish_suggestion_only
case_run 'Low/inconclusive/missing results cannot reuse old validated suggestions' test_finish_no_suggestion
case_run 'Existing owned shaping is retained until the sweep transaction' test_finish_reuse_queue
case_run 'Scan failures, invalid rates and inactive BBR never apply a cap' test_finish_failures
case_run 'Sweep transaction reuses the held lock and exports this run result' test_sweep_reuses_held_lock
case_run 'Integrated dry run performs no mutations or traffic' test_main_dry
case_run 'Cancelling reviewed smart plan performs no mutations or traffic' test_main_review_cancel
case_run 'Main applies base tuning before owned queue, scan and validated cap' test_main_sequence
case_run 'Smart menu runs full tuning once with explicit traffic and cap consent' test_menu_complete
case_run 'Smart menu can scan without applying its suggestion' test_menu_scan_only
case_run 'Declining scanning or traffic consent leaves only base tuning' test_menu_skip_scan
case_run 'Basic and legacy smart menu options remain usable' test_menu_basic_and_legacy
case_run 'Menu cancellation and container protection do not run live tuning' test_menu_cancel_container
case_run 'Menu dry-run preserves preview and exposes shaping management' test_menu_dry_and_advanced
if [[ ${SMART_TEST_REAL_TC:-0} == 1 ]]; then
    case_run 'Real isolated tc: full validated apply, repeat without new cap, and off' test_real_queue_workflow
fi
printf '\nSmart workflow: %s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
