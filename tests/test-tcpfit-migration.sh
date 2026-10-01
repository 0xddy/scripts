#!/usr/bin/env bash
# Explicit tcpfit migration tests. System tools and network traffic are mocked.
# Usage: bash tests/test-tcpfit-migration.sh [path/to/vps-tune.sh]
# Each case deliberately changes fixture globals only in its own subshell.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
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

assert_eq() {
    [[ $1 == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }
}

parse_ok() { (load_script; parse_args "$@"); }
parse_bad() {
    if (load_script; parse_args "$@"); then printf 'Unexpectedly accepted: %s\n' "$*" >&2; return 1; fi
}

migration_args() {
    MIGRATION_ARGS=(apply --kernel skip --smart-bandwidth --bandwidth-mbps 1000
        --rtt-ms 150 --smart-sweep --peer 192.0.2.1 --accept-traffic)
}

test_parser_explicit_only() {
    migration_args
    parse_ok "${MIGRATION_ARGS[@]}" --migrate-tcpfit
    parse_ok "${MIGRATION_ARGS[@]}" --migrate-tcpfit --apply-suggested-shape
    parse_ok "${MIGRATION_ARGS[@]}" --migrate-tcpfit --review
    parse_ok "${MIGRATION_ARGS[@]}" --migrate-tcpfit --dry-run
    parse_ok "${MIGRATION_ARGS[@]}"
    parse_bad apply --migrate-tcpfit
    parse_bad apply --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 150 --migrate-tcpfit
    parse_bad sweep --peer 192.0.2.1 --nominal-mbps 1000 --accept-traffic --migrate-tcpfit
    parse_bad shape --rate-mbps 1037 --migrate-tcpfit
    parse_bad shape --off --migrate-tcpfit
    parse_bad rollback --migrate-tcpfit
    parse_bad check --migrate-tcpfit
    parse_bad "${MIGRATION_ARGS[@]}" --migrate-tcpfit --container-test
    parse_bad "${MIGRATION_ARGS[@]}" --migrate-tcpfit --qdisc cake
    parse_bad "${MIGRATION_ARGS[@]}" --migrate-tcpfit --kernel lts
}

setup_preflight() {
    load_script
    STATE="$HARNESS_TMP/state"
    TMP="$HARNESS_TMP/tmp"
    TCPFIT_UNIT="$HARNESS_TMP/tcpfit-qdisc.service"
    TCPFIT_HELPER="$HARNESS_TMP/tcpfit-qdisc.sh"
    TCPFIT_MIGRATE=1
    SMART_SWEEP=1; ACTION=apply; KERNEL=skip; TEST=0; DRY=0
    CAPTURE_RATE=1037; CAPTURE_FAIL=0; HELPER_MATCH=0; UNIT_MATCH=0
    FLOCK_FAIL=0; DROPINS=''; NEED_RELOAD=no; UNIT_FILE_STATE=enabled; ACTIVE_STATE=active
    FILTER_PARENT=''; FRAGMENT_PATH=$TCPFIT_UNIT
    EVENTS="$HARNESS_TMP/preflight-events"
    : > "$EVENTS"
    cat > "$TCPFIT_UNIT" <<'EOF'
[Unit]
Description=tcpfit egress shaper
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/tcpfit-qdisc.sh 1037
[Install]
WantedBy=multi-user.target
EOF
    printf '#!/bin/bash\n# Fixture; parser implementation is tested separately.\n' > "$TCPFIT_HELPER"
    chmod 644 "$TCPFIT_UNIT"
    chmod 755 "$TCPFIT_HELPER"
    ensure_tmp() { mkdir -p "$TMP"; }
    flock() { return "$FLOCK_FAIL"; }
    shape_owned_files_guard() { :; }
    tcpfit_helper_matches() {
        assert_eq "$1" "$TCPFIT_HELPER"
        assert_eq "$2" "$CAPTURE_RATE"
        assert_eq "$3" test0
        return "$HELPER_MATCH"
    }
    tcpfit_unit_matches() {
        assert_eq "$1" "$TCPFIT_UNIT"
        assert_eq "$2" "$CAPTURE_RATE"
        return "$UNIT_MATCH"
    }
    tcpfit_queue_capture() {
        local iface=$1 dest=$2
        ((CAPTURE_FAIL == 0)) || return 1
        assert_eq "$iface" test0
        mkdir -p "$dest"
        [[ ! -e $dest/qdisc.json ]] || { printf 'Capture destination already used\n' >&2; return 1; }
        printf '[]\n' > "$dest/qdisc.json"
        printf '[]\n' > "$dest/class.json"
        printf 'qdisc htb 1: root default 0x10\nqdisc fq 10: parent 1:10 maxrate 1037Mbit\nclass htb 1:10 root rate 1037Mbit ceil 1037Mbit burst 518500b cburst 518500b\n' > "$dest/signature"
        printf '%s\0' qdisc replace dev test0 root handle 1: htb default 10 > "$dest/root.args"
        printf '%s\0' class replace dev test0 parent 1: classid 1:10 htb rate 1037mbit ceil 1037mbit burst 518500 cburst 518500 quantum 1514 > "$dest/class.args"
        printf '%s\0' qdisc replace dev test0 parent 1:10 handle 10: fq maxrate 1037mbit > "$dest/fq.args"
        TCPFIT_MIGRATION_RATE=$CAPTURE_RATE
        printf 'capture\n' >> "$EVENTS"
    }
    systemctl() {
        [[ ${1:-} == show ]] || { printf 'Unexpected systemd mutation: %s\n' "$*" >&2; return 90; }
        local arg
        for arg in "$@"; do
            case $arg in
                *FragmentPath*) printf '%s\n' "$FRAGMENT_PATH"; return ;;
                *DropInPaths*) printf '%s\n' "$DROPINS"; return ;;
                *NeedDaemonReload*) printf '%s\n' "$NEED_RELOAD"; return ;;
                *UnitFileState*) printf '%s\n' "$UNIT_FILE_STATE"; return ;;
                *ActiveState*) printf '%s\n' "$ACTIVE_STATE"; return ;;
            esac
        done
        printf 'Unexpected systemctl read: %s\n' "$*" >&2
        return 90
    }
    tc() {
        case $* in
            'qdisc show dev test0') printf 'qdisc htb 1: root default 0x10\nqdisc fq 10: parent 1:10 maxrate 1037Mbit\n' ;;
            'class show dev test0') printf 'class htb 1:10 root rate 1037Mbit ceil 1037Mbit burst 518500b cburst 518500b\n' ;;
            'filter show dev test0 root') [[ $FILTER_PARENT != root ]] || printf 'filter protocol all pref 1 u32\n' ;;
            'filter show dev test0 parent '*)
                [[ -z $FILTER_PARENT || ${*: -1} != "$FILTER_PARENT" ]] || printf 'filter protocol all pref 1 u32\n' ;;
            *) printf 'Unexpected queue mutation: %s\n' "$*" >&2; return 90 ;;
        esac
        return 0
    }
}

preflight_supported_environment() {
    [[ -f /.dockerenv && $EUID == 0 ]] || {
        printf 'Migration preflight fixtures run only in disposable Docker (lock path).\n'
        return 1
    }
}

test_standard_preflight() {
    preflight_supported_environment || return 0
    setup_preflight
    tcpfit_migration_preflight test0
    assert_eq "$TCPFIT_MIGRATION_NEEDED $TCPFIT_MIGRATION_IFACE $TCPFIT_MIGRATION_RATE" '1 test0 1037'
    [[ -d $TCPFIT_CANDIDATE && $TCPFIT_CANDIDATE == "$TMP"/* ]]
    [[ -s $TCPFIT_CANDIDATE/signature && -s $TCPFIT_CANDIDATE/root.args ]]
    [[ ! -e $STATE/tcpfit-migration ]]
}

test_preflight_rechecks_without_overwrite() {
    preflight_supported_environment || return 0
    setup_preflight
    tcpfit_migration_preflight test0
    local first=$TCPFIT_CANDIDATE first_hash
    first_hash=$(sha256sum "$first/signature")
    tcpfit_migration_preflight test0
    [[ $TCPFIT_CANDIDATE != "$first" && -s $TCPFIT_CANDIDATE/signature ]]
    assert_eq "$(sha256sum "$first/signature")" "$first_hash"
    assert_eq "$TCPFIT_MIGRATION_NEEDED $TCPFIT_MIGRATION_IFACE $TCPFIT_MIGRATION_RATE" '1 test0 1037'
}

test_preflight_rejects_unsupported_service() {
    preflight_supported_environment || return 0
    local fixture
    for fixture in fragment dropin reload unit-template helper-template queue-layout service-masked unstable-service lock-busy unit-mode helper-mode unit-link helper-link; do
        (
            setup_preflight
            case $fixture in
                fragment) FRAGMENT_PATH=/another/tcpfit-qdisc.service ;;
                dropin) DROPINS=/etc/systemd/system/tcpfit-qdisc.service.d/override.conf ;;
                reload) NEED_RELOAD=yes ;;
                unit-template) UNIT_MATCH=1 ;;
                helper-template) HELPER_MATCH=1 ;;
                queue-layout) CAPTURE_FAIL=1 ;;
                service-masked) UNIT_FILE_STATE=masked ;;
                unstable-service) ACTIVE_STATE=activating ;;
                lock-busy) FLOCK_FAIL=1 ;;
                unit-mode) chmod 666 "$TCPFIT_UNIT" ;;
                helper-mode) chmod 777 "$TCPFIT_HELPER" ;;
                unit-link) mv "$TCPFIT_UNIT" "$TCPFIT_UNIT.original"; ln -s "$TCPFIT_UNIT.original" "$TCPFIT_UNIT" ;;
                helper-link) mv "$TCPFIT_HELPER" "$TCPFIT_HELPER.original"; ln -s "$TCPFIT_HELPER.original" "$TCPFIT_HELPER" ;;
            esac
            (tcpfit_migration_preflight test0) &
            local child=$!
            if wait "$child"; then printf 'Unsafe migration accepted: %s\n' "$fixture" >&2; return 1; fi
            [[ ! -e $STATE/tcpfit-migration ]]
        )
        rm -rf -- "$HARNESS_TMP/tmp"
        rm -f -- "$HARNESS_TMP/tcpfit-qdisc.service" "$HARNESS_TMP/tcpfit-qdisc.sh" "$HARNESS_TMP/tcpfit-qdisc.service.original" "$HARNESS_TMP/tcpfit-qdisc.sh.original"
    done
}

test_preflight_rejects_old_tree_filters() {
    preflight_supported_environment || return 0
    local parent
    for parent in root 1: 1:10 10:; do
        (
            setup_preflight
            FILTER_PARENT=$parent
            (tcpfit_migration_preflight test0) &
            local child=$!
            if wait "$child"; then printf 'Accepted old-tree filter at %s\n' "$parent" >&2; return 1; fi
            [[ ! -e $STATE/tcpfit-migration ]]
        )
        rm -rf -- "$HARNESS_TMP/tmp"
    done
}

setup_committed_backup() {
    setup_preflight
    UNIT_FILE_STATE=${1:-enabled}; ACTIVE_STATE=${2:-active}
    tcpfit_migration_preflight test0
    local backup="$STATE/tcpfit-migration"
    mkdir -p "$backup/original"
    cp -a "$TCPFIT_CANDIDATE/." "$backup/original/"
    isolated_tools_fingerprint "$backup/original" > "$backup/original.sha256"
    printf 'committed\n' > "$backup/status"
    rm -- "$TCPFIT_UNIT" "$TCPFIT_HELPER"
    UNIT_FILE_STATE=disabled; ACTIVE_STATE=inactive
    DEFAULT_IFACE=test0
    RESTORE_EVENTS="$HARNESS_TMP/restore-events"
    : > "$RESTORE_EVENTS"
    ip() {
        case $* in
            '-o -4 route show default') printf 'default via 192.0.2.254 dev %s\n' "$DEFAULT_IFACE" ;;
            '-o -6 route show default') : ;;
            *) return 91 ;;
        esac
    }
    systemctl() {
        if [[ $1 == show ]]; then
            local arg
            for arg in "$@"; do
                case $arg in
                    *DropInPaths*) printf '%s\n' "$DROPINS"; return ;;
                    *UnitFileState*) printf '%s\n' "$UNIT_FILE_STATE"; return ;;
                    *ActiveState*) printf '%s\n' "$ACTIVE_STATE"; return ;;
                esac
            done
            return 91
        fi
        printf '%s\n' "$1" >> "$RESTORE_EVENTS"
        case $1 in
            daemon-reload) : ;;
            enable) UNIT_FILE_STATE=enabled ;;
            disable) UNIT_FILE_STATE=disabled ;;
            start) ACTIVE_STATE=active ;;
            stop) ACTIVE_STATE=inactive ;;
            *) return 91 ;;
        esac
    }
    tcpfit_queue_restore() {
        assert_eq "$1" test0
        assert_eq "$(cat "$2/rate")" 1037
        printf 'restore-queue:1037\n' >> "$RESTORE_EVENTS"
    }
}

test_committed_rollback_preserves_previous_state() {
    preflight_supported_environment || return 0
    local enabled active expected
    for enabled in enabled disabled; do
        for active in active inactive; do
            (
                setup_committed_backup "$enabled" "$active"
                tcpfit_migration_rollback
                assert_eq "$(tcpfit_migration_state)" restored
                assert_eq "$UNIT_FILE_STATE $ACTIVE_STATE" "$enabled $active"
                cmp "$TCPFIT_UNIT" "$STATE/tcpfit-migration/original/tcpfit.unit"
                cmp "$TCPFIT_HELPER" "$STATE/tcpfit-migration/original/tcpfit.helper"
                expected=daemon-reload
                if [[ $enabled == enabled ]]; then expected+=$'\nenable'; else expected+=$'\ndisable'; fi
                if [[ $active == active ]]; then expected+=$'\nstart'; else expected+=$'\nstop'; fi
                expected+=$'\nrestore-queue:1037'
                assert_eq "$(cat "$RESTORE_EVENTS")" "$expected"
                tcpfit_migration_rollback
                assert_eq "$(cat "$RESTORE_EVENTS")" "$expected"
            )
            rm -rf -- "$HARNESS_TMP/state" "$HARNESS_TMP/tmp"
        done
    done
}

test_rollback_preserves_later_changes() {
    preflight_supported_environment || return 0
    local fixture
    for fixture in unit helper dropin interface backup-content backup-mode; do
        (
            setup_committed_backup
            case $fixture in
                unit) printf 'later administrator unit\n' > "$TCPFIT_UNIT" ;;
                helper) printf 'later administrator helper\n' > "$TCPFIT_HELPER" ;;
                dropin) DROPINS=/etc/systemd/system/tcpfit-qdisc.service.d/new.conf ;;
                interface) DEFAULT_IFACE=other0 ;;
                backup-content) printf 'changed\n' >> "$STATE/tcpfit-migration/original/signature" ;;
                backup-mode) chmod 600 "$STATE/tcpfit-migration/original/tcpfit.helper" ;;
            esac
            (tcpfit_migration_rollback) &
            local child=$!
            if wait "$child"; then printf 'Restored over conflict: %s\n' "$fixture" >&2; return 1; fi
            [[ ! -s $RESTORE_EVENTS ]]
            assert_eq "$(tcpfit_migration_state)" committed
            if [[ $fixture == unit ]]; then assert_eq "$(cat "$TCPFIT_UNIT")" 'later administrator unit'; fi
            if [[ $fixture == helper ]]; then assert_eq "$(cat "$TCPFIT_HELPER")" 'later administrator helper'; fi
        )
        rm -rf -- "$HARNESS_TMP/state" "$HARNESS_TMP/tmp"
    done
}

test_full_rollback_checks_migration_before_config_changes() {
    preflight_supported_environment || return 0
    local fixture
    for fixture in unit helper dropin backup-content; do
        (
            setup_committed_backup
            local config="$HARNESS_TMP/managed.conf"
            mkdir -p "$STATE/original$(dirname "$config")" "$STATE/expected$(dirname "$config")"
            printf 'new-managed-value\n' > "$config"
            printf 'old-original-value\n' > "$STATE/original$config"
            cp "$config" "$STATE/expected$config"
            printf '%s\n' "$config" > "$STATE/manifest"
            : > "$STATE/runtime.before"
            TEST=1
            case $fixture in
                unit) printf 'later unit\n' > "$TCPFIT_UNIT" ;;
                helper) printf 'later helper\n' > "$TCPFIT_HELPER" ;;
                dropin) DROPINS=/etc/systemd/system/tcpfit-qdisc.service.d/new.conf ;;
                backup-content) printf 'changed\n' >> "$STATE/tcpfit-migration/original/signature" ;;
            esac
            (rollback) &
            local child=$!
            if wait "$child"; then printf 'Full rollback ignored migration conflict: %s\n' "$fixture" >&2; return 1; fi
            assert_eq "$(cat "$config")" 'new-managed-value'
            [[ ! -s $RESTORE_EVENTS ]]
        )
        rm -rf -- "$HARNESS_TMP/state" "$HARNESS_TMP/tmp"
    done
}

test_migration_state_guard() {
    preflight_supported_environment || return 0
    setup_committed_backup
    local action
    tcpfit_set_migration_state pending
    for action in apply shape sweep queue; do
        if (ACTION=$action; tcpfit_migration_guard); then printf 'Pending migration allowed %s\n' "$action" >&2; return 1; fi
    done
    for action in rollback check menu; do ACTION=$action; tcpfit_migration_guard; done
    tcpfit_set_migration_state unknown-state
    if (ACTION=apply; tcpfit_migration_guard); then printf 'Unknown migration status accepted\n' >&2; return 1; fi
    tcpfit_set_migration_state committed
    ACTION=apply; tcpfit_migration_guard
    printf 'later helper\n' > "$TCPFIT_HELPER"
    if (tcpfit_migration_guard); then printf 'Two concurrent shapers accepted\n' >&2; return 1; fi
    for action in rollback check menu; do ACTION=$action; tcpfit_migration_guard; done
    [[ ! -s $RESTORE_EVENTS ]]
}

test_failed_state_write_preserves_previous_marker() {
    load_script
    STATE="$HARNESS_TMP/state-write"
    mkdir -p "$STATE/tcpfit-migration"
    printf 'committed\n' > "$STATE/tcpfit-migration/status"
    printf() {
        if [[ ${1:-} == '%s\n' && ${2:-} == restored ]]; then return 73; fi
        # Transparent wrapper around printf.
        # shellcheck disable=SC2059
        builtin printf "$@"
    }
    # Abort/rollback call helpers conditionally: do not depend on errexit to
    # keep a failed marker write from replacing a previously committed state.
    if tcpfit_set_migration_state restored; then
        builtin printf 'Failed state write reported success\n' >&2
        return 1
    fi
    assert_eq "$(cat "$STATE/tcpfit-migration/status")" committed
}

setup_menu() {
    load_script
    TCPFIT_UNIT="$HARNESS_TMP/menu-tcpfit.service"
    TCPFIT_HELPER="$HARNESS_TMP/menu-tcpfit.sh"
    rm -f -- "$TCPFIT_UNIT" "$TCPFIT_HELPER"
    MENU_NOFILE=1048576; MENU_CPU=auto; MENU_DKMS=0
    TEST=0; DRY=0
    MENU_CAPTURE="$HARNESS_TMP/menu-args"
    MENU_CALLS="$HARNESS_TMP/menu-calls"
    : > "$MENU_CAPTURE"; : > "$MENU_CALLS"
    is_container() { return 1; }
    menu_run() { printf '%s\n' "$@" > "$MENU_CAPTURE"; printf 'run\n' >> "$MENU_CALLS"; }
}

menu_has() { grep -Fxq -- "$1" "$MENU_CAPTURE"; }
menu_lacks() { if menu_has "$1"; then printf 'Unexpected option: %s\n' "$1" >&2; return 1; fi; }
menu_parses() { local -a args=(); mapfile -t args < "$MENU_CAPTURE"; parse_ok "${args[@]}"; }

test_menu_migration_requires_consent() {
    setup_menu
    printf 'present\n' > "$TCPFIT_UNIT"
    menu_smart <<< $'1\n5\n2\n1000\ny\niperf.example.com\ny\ny\ny'
    assert_eq "$(cat "$MENU_CALLS")" run
    menu_has --migrate-tcpfit
    menu_has --smart-sweep
    menu_has --accept-traffic
    menu_parses
    setup_menu
    printf 'present\n' > "$TCPFIT_HELPER"
    menu_smart <<< $'1\n5\n2\n1000\ny\niperf.example.com\ny\ny\nn'
    assert_eq "$(cat "$MENU_CALLS")" ''
    setup_menu
    printf 'present\n' > "$TCPFIT_UNIT"
    menu_smart <<< $'1\n5\n2\n1000\ny\niperf.example.com\ny\ny'
    assert_eq "$(cat "$MENU_CALLS")" ''
}

test_menu_no_migration_for_absent_files_or_base_only() {
    setup_menu
    menu_smart <<< $'1\n5\n2\n1000\ny\niperf.example.com\ny\ny'
    assert_eq "$(cat "$MENU_CALLS")" run
    menu_lacks --migrate-tcpfit
    menu_parses
    setup_menu
    printf 'present\n' > "$TCPFIT_UNIT"
    menu_smart <<< $'1\n5\n2\n1000\nn'
    assert_eq "$(cat "$MENU_CALLS")" run
    menu_lacks --migrate-tcpfit
    menu_lacks --smart-sweep
    menu_parses
}

test_menu_migration_preview() {
    setup_menu
    printf 'present\n' > "$TCPFIT_HELPER"
    DRY=1
    menu_smart <<< $'1\n5\n2\n1000\ny\niperf.example.com\ny\ny'
    assert_eq "$(cat "$MENU_CALLS")" run
    menu_has --dry-run
    menu_has --migrate-tcpfit
    menu_has --smart-sweep
    menu_lacks --accept-traffic
    menu_parses
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

case_run 'Migration flag requires an explicitly authorized integrated scan' test_parser_explicit_only
case_run 'Known 1037 Mbit tcpfit service/tree produce only a temporary candidate' test_standard_preflight
case_run 'Repeated preflight captures fresh candidates without altering earlier evidence' test_preflight_rechecks_without_overwrite
case_run 'Migration rejects unknown service/template/tree or symlink ownership' test_preflight_rejects_unsupported_service
case_run 'Filters on every tcpfit parent prevent takeover' test_preflight_rejects_old_tree_filters
case_run 'Rollback preserves original rate, enablement and activation states idempotently' test_committed_rollback_preserves_previous_state
case_run 'Rollback refuses later file/service/interface changes or damaged backups' test_rollback_preserves_later_changes
case_run 'Full rollback rejects tcpfit conflicts before touching managed configuration' test_full_rollback_checks_migration_before_config_changes
case_run 'Pending migration and recreated tcpfit files block conflicting actions' test_migration_state_guard
case_run 'A failed state marker write preserves the previous committed state' test_failed_state_write_preserves_previous_marker
case_run 'Menu migration requires a separate yes and cancellation runs nothing' test_menu_migration_requires_consent
case_run 'Absent tcpfit files and base-only tuning do not authorize migration' test_menu_no_migration_for_absent_files_or_base_only
case_run 'Migration preview carries dry-run and performs no traffic consent side effect' test_menu_migration_preview
printf '\nTcpfit migration: %s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
