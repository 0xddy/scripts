#!/usr/bin/env bash
# Deterministic isolated dependency tests. All packages and commands are local
# fixtures; no package manager, download, sysctl or network operation is run.
# Usage: bash tests/test-isolated-tools.sh [path/to/vps-tune.sh]
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
trap 'if [[ $BASHPID == "$HARNESS_OWNER_PID" ]]; then PATH=$HARNESS_PATH; rm -rf -- "$HARNESS_TMP"; fi' EXIT

load_script() {
    # shellcheck source=/dev/null
    source "$SCRIPT"
    PATH=$HARNESS_PATH
    trap - ERR INT TERM
    trap 'if [[ $BASHPID == "$HARNESS_OWNER_PID" ]]; then PATH=$HARNESS_PATH; rm -rf -- "$HARNESS_TMP"; fi' EXIT
}

assert_eq() {
    [[ $1 == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }
}

setup_tools() {
    load_script
    STATE="$HARNESS_TMP/state"
    TMP="$HARNESS_TMP/tmp"
    HOST_BIN="$HARNESS_TMP/host-bin"
    SUPPORT_BIN="$HARNESS_TMP/support-bin"
    BUILD_LOG="$HARNESS_TMP/build.log"
    BUILD_FAIL=0
    mkdir -p "$HOST_BIN" "$SUPPORT_BIN"
    : > "$BUILD_LOG"
    # The controlled PATH deliberately excludes system scan dependencies while
    # keeping the ordinary file/text utilities needed by the real functions.
    local name executable
    for name in bash mkdir mktemp cat chmod mv find sort sha256sum readlink realpath stat cp cmp sed awk grep install ln cut basename dirname rm uname id wc date tr head tail touch tee env od uniq xargs readelf; do
        executable=$(type -P "$name") || continue
        ln -s "$executable" "$SUPPORT_BIN/$name"
    done
    for name in ip tc sysctl modprobe modinfo iperf3 jq timeout getent; do
        printf '#!/usr/bin/env bash\nprintf "host %s\\n"\n' "$name" > "$HOST_BIN/$name"
        chmod 755 "$HOST_BIN/$name"
    done
    ensure_tmp() { mkdir -p "$TMP"; }
    isolated_tools_build() {
        local dest=$1 package command
        shift
        printf '%s\n' "$@" >> "$BUILD_LOG"
        ((BUILD_FAIL == 0)) || return 42
        mkdir -p "$dest/bin" "$dest/share"
        printf 'private-fixture\n' > "$dest/share/token"
        printf 'alternate-fixture\n' > "$dest/share/alternate"
        ln -s token "$dest/share/current"
        local -a commands=()
        for package in "$@"; do
            case $package in
                iproute2) commands+=(ip tc) ;;
                procps) commands+=(sysctl) ;;
                kmod) commands+=(modprobe modinfo) ;;
                iperf3) commands+=(iperf3) ;;
                jq) commands+=(jq) ;;
                coreutils) commands+=(timeout) ;;
                libc-bin) commands+=(getent) ;;
            esac
        done
        for command in "${commands[@]}"; do
            cat > "$dest/bin/$command" <<'EOF'
#!/usr/bin/env bash
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf '%s %s\n' "$(cat "$root/share/current")" "$(basename "$0")"
EOF
            chmod 755 "$dest/bin/$command"
        done
    }
    PATH="$HOST_BIN:$SUPPORT_BIN"
}

drop_tools() { local name; for name in "$@"; do rm -f -- "$HOST_BIN/$name"; done; }

test_complete_reuses_host() {
    setup_tools
    local before=$PATH
    prepare_scan_tools
    assert_eq "$PATH" "$before"
    assert_eq "$PERSIST_SCAN_TOOLS" 0
    [[ ! -s $BUILD_LOG && ! -e $TMP && ! -e $STATE ]]
}

test_measurement_tools_temporary() {
    setup_tools
    drop_tools iperf3 jq timeout getent
    prepare_scan_tools
    assert_eq "$PERSIST_SCAN_TOOLS" 0
    [[ $SCAN_TOOLS_ROOT == "$TMP"/* && -d $SCAN_TOOLS_ROOT ]]
    local name
    for name in iperf3 jq timeout getent; do
        [[ $(command -v "$name") == "$SCAN_TOOLS_ROOT"/* ]]
        assert_eq "$("$name")" "private-fixture $name"
    done
    for name in ip tc sysctl modprobe modinfo; do assert_eq "$(command -v "$name")" "$HOST_BIN/$name"; done
    [[ ! -e $STATE ]]
    persist_scan_tools
    [[ ! -e $STATE ]]
    cleanup
    [[ ! -e $TMP && ! -e $STATE ]]
}

test_partial_package_keeps_host_version() {
    setup_tools
    drop_tools tc
    prepare_scan_tools
    assert_eq "$PERSIST_SCAN_TOOLS" 1
    assert_eq "$(command -v ip)" "$HOST_BIN/ip"
    assert_eq "$(ip -Version)" 'host ip'
    assert_eq "$(tc)" 'private-fixture tc'
    [[ ! -e $SCAN_TOOLS_ROOT/bin/ip ]]
    assert_eq "$(cat "$BUILD_LOG")" iproute2
}

test_migration_keeps_json_parser_for_rollback() {
    setup_tools
    drop_tools jq
    TCPFIT_MIGRATE=1
    prepare_scan_tools
    assert_eq "$PERSIST_SCAN_TOOLS" 1
    init_state
    persist_scan_tools
    local retained=$SCAN_TOOLS_ROOT
    cleanup
    [[ -d $retained && ! -e $TMP ]]
    PATH="$HOST_BIN:$SUPPORT_BIN"
    activate_persistent_tools
    assert_eq "$(jq)" 'private-fixture jq'
}

test_queue_dependencies_persist_flag() {
    local missing
    for missing in ip tc sysctl modprobe modinfo; do
        (
            setup_tools
            drop_tools "$missing"
            prepare_scan_tools
            assert_eq "$PERSIST_SCAN_TOOLS" 1
            [[ ! -e $STATE ]]
            assert_eq "$("$missing")" "private-fixture $missing"
        )
        PATH=$HARNESS_PATH
        rm -rf -- "$HARNESS_TMP/host-bin" "$HARNESS_TMP/support-bin" "$HARNESS_TMP/tmp"
    done
}

test_dry_run_no_changes() {
    setup_tools
    drop_tools ip tc sysctl modprobe modinfo iperf3 jq timeout getent
    DRY=1
    local before=$PATH
    prepare_scan_tools
    assert_eq "$PATH" "$before"
    [[ ! -s $BUILD_LOG && ! -e $TMP && ! -e $STATE ]]
}

test_failed_build_no_state() {
    setup_tools
    drop_tools iperf3
    BUILD_FAIL=1
    # A separate asynchronous subshell preserves errexit within preparation.
    (prepare_scan_tools) &
    local child=$!
    if wait "$child"; then printf 'Failed bundle build was accepted\n' >&2; return 1; fi
    [[ ! -e $STATE && -s $BUILD_LOG ]]
}

test_persist_and_relocate() {
    setup_tools
    drop_tools tc jq
    prepare_scan_tools
    local temporary=$SCAN_TOOLS_ROOT digest initial_path
    digest=$(isolated_tools_fingerprint "$temporary")
    [[ $digest =~ ^[a-f0-9]{64}$ ]]
    init_state
    persist_scan_tools
    assert_eq "$SCAN_TOOLS_ROOT" "$STATE/tools/$digest"
    assert_eq "$PERSIST_SCAN_TOOLS" 0
    assert_eq "$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")" "$digest"
    assert_eq "$(tc)" 'private-fixture tc'
    assert_eq "$(command -v ip)" "$HOST_BIN/ip"
    [[ -d $SCAN_TOOLS_ROOT && -z ${TOOLS_STAGING:-} ]]
    cleanup
    [[ ! -e $TMP && -d $SCAN_TOOLS_ROOT ]]
    PATH="$HOST_BIN:$SUPPORT_BIN"
    activate_persistent_tools
    initial_path=$PATH
    assert_eq "$(tc)" 'private-fixture tc'
    assert_eq "$(jq)" 'private-fixture jq'
    activate_persistent_tools
    assert_eq "$PATH" "$initial_path"
}

test_content_addressed_reuse() {
    setup_tools
    drop_tools tc
    prepare_scan_tools
    init_state
    persist_scan_tools
    local first=$SCAN_TOOLS_ROOT first_identity first_hash second
    first_identity=$(stat -c '%i:%y' "$first/bin/tc")
    first_hash=$(isolated_tools_fingerprint "$first")
    # Re-persisting identical bytes reuses the immutable object unchanged.
    cp -a "$first" "$HARNESS_TMP/again"
    SCAN_TOOLS_ROOT="$HARNESS_TMP/again"; PERSIST_SCAN_TOOLS=1
    persist_scan_tools
    assert_eq "$SCAN_TOOLS_ROOT" "$first"
    assert_eq "$(stat -c '%i:%y' "$first/bin/tc")" "$first_identity"
    # A newer bundle receives a new digest; the old boot helper's root survives.
    cp -a "$first" "$HARNESS_TMP/new"
    printf 'private-fixture-v2\n' > "$HARNESS_TMP/new/share/token"
    second=$(isolated_tools_fingerprint "$HARNESS_TMP/new")
    [[ $second != "$first_hash" ]]
    SCAN_TOOLS_ROOT="$HARNESS_TMP/new"; PERSIST_SCAN_TOOLS=1
    persist_scan_tools
    assert_eq "$SCAN_TOOLS_ROOT" "$STATE/tools/$second"
    assert_eq "$(isolated_tools_fingerprint "$first")" "$first_hash"
    assert_eq "$(stat -c '%i:%y' "$first/bin/tc")" "$first_identity"
    [[ -d $first && -d $SCAN_TOOLS_ROOT ]]
}

test_fingerprint_content_mode_and_symlink() {
    setup_tools
    drop_tools tc
    prepare_scan_tools
    local digest
    digest=$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")
    chmod 700 "$SCAN_TOOLS_ROOT"
    [[ $(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT") != "$digest" ]]
    chmod 755 "$SCAN_TOOLS_ROOT"
    assert_eq "$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")" "$digest"
    touch "$SCAN_TOOLS_ROOT/share/token"
    assert_eq "$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")" "$digest"
    chmod 600 "$SCAN_TOOLS_ROOT/share/token"
    [[ $(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT") != "$digest" ]]
    chmod 644 "$SCAN_TOOLS_ROOT/share/token"
    assert_eq "$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")" "$digest"
    rm -f -- "$SCAN_TOOLS_ROOT/share/current"
    ln -s alternate "$SCAN_TOOLS_ROOT/share/current"
    [[ $(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT") != "$digest" ]]
}

test_activation_rejects_tampering() {
    local mutation
    for mutation in bytes mode symlink missing; do
        (
            setup_tools
            drop_tools tc
            prepare_scan_tools
            init_state
            persist_scan_tools
            case $mutation in
                bytes) printf 'changed\n' >> "$SCAN_TOOLS_ROOT/share/token" ;;
                mode) chmod 600 "$SCAN_TOOLS_ROOT/bin/tc" ;;
                symlink) rm -f -- "$SCAN_TOOLS_ROOT/share/current"; ln -s alternate "$SCAN_TOOLS_ROOT/share/current" ;;
                missing) rm -f -- "$SCAN_TOOLS_ROOT/bin/tc" ;;
            esac
            PATH="$HOST_BIN:$SUPPORT_BIN"
            if (activate_persistent_tools); then printf 'Accepted tampered bundle: %s\n' "$mutation" >&2; return 1; fi
        )
        PATH=$HARNESS_PATH
        rm -rf -- "$HARNESS_TMP/host-bin" "$HARNESS_TMP/support-bin" "$HARNESS_TMP/tmp" "$HARNESS_TMP/state"
    done
}

test_activation_read_only_and_staging() {
    setup_tools
    drop_tools tc
    prepare_scan_tools
    init_state
    persist_scan_tools
    local digest identity
    digest=$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")
    identity=$(stat -c '%i:%y' "$SCAN_TOOLS_ROOT/bin/tc")
    mkdir -p "$STATE/tools/.staging.unfinished/bin"
    printf 'incomplete\n' > "$STATE/tools/.staging.unfinished/bin/tc"
    chmod 755 "$STATE/tools/.staging.unfinished/bin/tc"
    DRY=1; PATH="$HOST_BIN:$SUPPORT_BIN"
    activate_persistent_tools
    assert_eq "$(isolated_tools_fingerprint "$SCAN_TOOLS_ROOT")" "$digest"
    assert_eq "$(stat -c '%i:%y' "$SCAN_TOOLS_ROOT/bin/tc")" "$identity"
    [[ -f $STATE/tools/.staging.unfinished/bin/tc ]]
    assert_eq "$(tc)" 'private-fixture tc'
}

test_persistence_refreshes_existing_boot_helper() {
    setup_tools
    drop_tools tc
    prepare_scan_tools
    init_state
    mkdir -p "$STATE/shaping"
    printf 'test0 530\n' > "$STATE/shaping/active"
    local events="$HARNESS_TMP/helper-events"
    : > "$events"
    shape_owned_files_guard() { printf 'guard\n' >> "$events"; }
    shape_write_service() { printf 'helper:%s:%s\n' "$SHAPE_IFACE" "$SHAPE_RATE" >> "$events"; }
    persist_scan_tools
    assert_eq "$(cat "$events")" $'guard\nhelper:test0:530'
    assert_eq "$(cat "$STATE/shaping/active")" 'test0 530'
    persist_scan_tools
    assert_eq "$(cat "$events")" $'guard\nhelper:test0:530'
}

test_temporary_tools_preserve_boot_helper() {
    setup_tools
    drop_tools jq
    prepare_scan_tools
    mkdir -p "$STATE/shaping"
    printf 'test0 530\n' > "$STATE/shaping/active"
    shape_owned_files_guard() { printf 'Unexpected helper guard for temporary tools\n' >&2; return 99; }
    shape_write_service() { printf 'Unexpected helper rewrite for temporary tools\n' >&2; return 99; }
    persist_scan_tools
    assert_eq "$PERSIST_SCAN_TOOLS" 0
    assert_eq "$(cat "$STATE/shaping/active")" 'test0 530'
    [[ ! -e $STATE/tools ]]
}

test_standalone_invalid_peer_does_not_persist() {
    load_script
    STATE="$HARNESS_TMP/standalone-state"
    local events="$HARNESS_TMP/standalone-events" fixture
    : > "$events"
    ACTION=sweep; SWEEP_PEER=authorized.example; SWEEP_NOMINAL=500
    TUNE_LOCK_HELD=1; PERSIST_SCAN_TOOLS=1
    preflight() { :; }
    shape_read_active() { SHAPE_ACTIVE_IFACE=; SHAPE_ACTIVE_RATE=; }
    shape_require_owned() { :; }
    shape_owned_files_guard() { :; }
    shape_signature() { printf 'qdisc fq 7a00: root limit 10000p\n'; }
    init_state() { mkdir -p "$STATE"; printf 'init\n' >> "$events"; }
    persist_scan_tools() { printf 'persist\n' >> "$events"; }
    ip() {
        case $* in
            '-o -4 route show default') printf 'default via 192.0.2.254 dev test0\n' ;;
            '-o -6 route show default') : ;;
            'route get 192.0.2.1') printf '192.0.2.1 dev other0 src 198.51.100.2\n' ;;
            *) return 99 ;;
        esac
    }
    getent() { [[ $fixture != dns ]] || return 0; printf '192.0.2.1 STREAM peer\n'; }
    tc() { return 99; }
    jq() { return 99; }
    iperf3() { return 99; }
    timeout() { return 99; }
    for fixture in dns wrong-route; do
        (run_shape_action) &
        local child=$!
        if wait "$child"; then printf 'Invalid peer accepted: %s\n' "$fixture" >&2; return 1; fi
        [[ ! -e $STATE && ! -s $events ]]
    done
}

setup_main_flow() {
    load_script
    STATE="$HARNESS_TMP/main-state"
    EVENTS="$HARNESS_TMP/main-events"
    : > "$EVENTS"
    check_os() { VERSION_ID=13; CODENAME=trixie; }
    configured_qdisc() { printf 'fq\n'; }
    is_container() { return 1; }
    preflight() { :; }
    flock() { :; }
    resolve_rtt() { :; }
    resolve_bandwidth() { :; }
    choose_plan() { MEM_MIB=1024; BUFFER=14; }
    buffer_plan_description() { printf 'fixture plan\n'; }
    show_buffer_notice() { :; }
    show_tuning_plan() { :; }
    show_smart_sweep_plan() { :; }
    show_completion() { :; }
    activate_persistent_tools() { printf 'activate\n' >> "$EVENTS"; }
    prepare_scan_tools() { printf 'prepare\n' >> "$EVENTS"; PERSIST_SCAN_TOOLS=1; }
    persist_scan_tools() { printf 'persist\n' >> "$EVENTS"; }
    smart_sweep_preflight() { printf 'validate\n' >> "$EVENTS"; }
    init_state() { printf 'init\n' >> "$EVENTS"; }
    install_kernel() { printf 'kernel\n' >> "$EVENTS"; }
    configure_limits() { printf 'limits\n' >> "$EVENTS"; }
    configure_network() { printf 'network\n' >> "$EVENTS"; }
    apply_runtime() { printf 'runtime\n' >> "$EVENTS"; }
    smart_finish_tuning() { printf 'scan\n' >> "$EVENTS"; }
    review_tuning_plan() { printf 'review\n' >> "$EVENTS"; return "${REVIEW_STATUS:-0}"; }
    sysctl() { return 98; }
    modprobe() { return 98; }
    tc() { return 98; }
    apt_update() { printf 'Unexpected package operation\n' >&2; return 98; }
    apt_install() { printf 'Unexpected package operation\n' >&2; return 98; }
    FLOW_ARGS=(apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100
        --smart-sweep --peer 192.0.2.1 --accept-traffic --apply-suggested-shape --review)
}

assert_event_before() {
    awk -v first="$1" -v second="$2" '$0==first&&!a{a=NR}$0==second&&!b{b=NR}END{exit !(a&&b&&a<b)}' "$EVENTS" || {
        printf 'Wrong event order: %s before %s\n' "$1" "$2" >&2
        cat "$EVENTS" >&2
        return 1
    }
}

test_main_confirmation_order() {
    [[ -f /.dockerenv && $EUID == 0 ]] || { printf 'Full main flow runs only inside disposable Docker\n'; return 0; }
    setup_main_flow
    REVIEW_STATUS=0
    main "${FLOW_ARGS[@]}"
    assert_event_before activate review
    assert_event_before review prepare
    assert_event_before prepare validate
    assert_event_before validate init
    assert_event_before init persist
    assert_event_before persist limits
    assert_event_before persist network
    assert_event_before runtime scan
}

test_main_cancel_and_dry() {
    [[ -f /.dockerenv && $EUID == 0 ]] || { printf 'Full main flow runs only inside disposable Docker\n'; return 0; }
    setup_main_flow
    REVIEW_STATUS=1
    main "${FLOW_ARGS[@]}"
    assert_eq "$(cat "$EVENTS")" $'activate\nreview'
    setup_main_flow
    main "${FLOW_ARGS[@]}" --dry-run
    assert_eq "$(cat "$EVENTS")" activate
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

case_run 'Complete host dependencies are reused without downloads or writes' test_complete_reuses_host
case_run 'Measurement-only dependencies stay temporary and are cleaned up' test_measurement_tools_temporary
case_run 'A partial package never shadows an existing host command' test_partial_package_keeps_host_version
case_run 'Explicit migration retains missing jq for a later full rollback' test_migration_keeps_json_parser_for_rollback
case_run 'Queue/runtime dependencies request persistent retention' test_queue_dependencies_persist_flag
case_run 'Dry-run does not download, install, create paths or change PATH' test_dry_run_no_changes
case_run 'A failed isolated build cannot write persistent state' test_failed_build_no_state
case_run 'A persisted bundle remains executable after relocation and cleanup' test_persist_and_relocate
case_run 'Content-addressed bundles reuse identical bytes and retain old versions' test_content_addressed_reuse
case_run 'Fingerprints cover content, modes and symlink targets, but not mtime' test_fingerprint_content_mode_and_symlink
case_run 'Activation rejects tampered content, modes, links and missing files' test_activation_rejects_tampering
case_run 'Dry activation is read-only and ignores interrupted staging copies' test_activation_read_only_and_staging
case_run 'Retained runtime refreshes an owned boot helper without changing its cap' test_persistence_refreshes_existing_boot_helper
case_run 'Measurement-only temporary tools do not rewrite an existing boot helper' test_temporary_tools_preserve_boot_helper
case_run 'Standalone sweep rejects unresolved/off-interface peers before persistence' test_standalone_invalid_peer_does_not_persist
case_run 'Confirmed flow prepares then validates before persisting/configuring' test_main_confirmation_order
case_run 'Cancelling or previewing the main plan does not prepare or persist tools' test_main_cancel_and_dry
printf '\nIsolated tools: %s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
