#!/usr/bin/env bash
# Run with Bash on Linux or Git Bash. Every external host mutation is mocked.
# Usage: bash tests/test-vps-tune.sh [path/to/vps-tune.sh]
# Sourced code consumes test globals and invokes mocked functions indirectly.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
target_script=${1:-${TARGET_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../vps-tune.sh}}
SCRIPT=$(cd "$(dirname "$target_script")" && pwd)/$(basename "$target_script")
HARNESS_PATH=$PATH
HARNESS_TMP=$(mktemp -d)
trap 'rm -rf -- "$HARNESS_TMP"' EXIT
passed=0
failed=0

load_script() {
    # shellcheck source=/dev/null
    source "$SCRIPT"
    PATH=$HARNESS_PATH
    trap - EXIT ERR INT TERM
}

assert_eq() {
    [[ $1 == "$2" ]] || { printf 'FAIL expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; }
}

case_run() {
    local name=$1
    shift
    [[ -z ${TEST_FILTER:-} || $name == *"$TEST_FILTER"* ]] || return 0
    if (set -e; "$@") >"$HARNESS_TMP/case.log" 2>&1; then
        printf 'PASS %s\n' "$name"
        passed=$((passed+1))
    else
        printf 'FAIL %s\n' "$name"
        cat "$HARNESS_TMP/case.log"
        failed=$((failed+1))
    fi
}

test_write_idempotence() {
    load_script
    local sandbox="$HARNESS_TMP/write-idempotence" identity attempt
    mkdir -p "$sandbox"
    STATE="$sandbox/state"; SYSCTL="$sandbox/tuned.conf"
    printf 'net.core.rmem_max = 4194304\n' > "$SYSCTL"
    cp "$SYSCTL" "$sandbox/original"
    identity=$(stat -c '%i:%y' "$SYSCTL")
    init_state
    # The very first write must register an identical pre-existing file without
    # replacing its inode, and must retain a snapshot for future rollback.
    for attempt in 1 2 3; do
        write_file "$SYSCTL" < "$sandbox/original" || return
        assert_eq "$(stat -c '%i:%y' "$SYSCTL")" "$identity" || return
        cmp "$sandbox/original" "$SYSCTL" || return
        cmp "$sandbox/original" "$STATE/original$SYSCTL" || return
        cmp "$sandbox/original" "$STATE/expected$SYSCTL" || return
        assert_eq "$(wc -l < "$STATE/manifest")" 1 || return
    done
    printf 'net.core.rmem_max = 8388608\n' | write_file "$SYSCTL" || return
    assert_eq "$(cat "$SYSCTL")" 'net.core.rmem_max = 8388608' || return
    cmp "$sandbox/original" "$STATE/original$SYSCTL" || return
    identity=$(stat -c '%i:%y' "$SYSCTL")
    for attempt in 1 2 3; do
        printf 'net.core.rmem_max = 8388608\n' | write_file "$SYSCTL" || return
        assert_eq "$(stat -c '%i:%y' "$SYSCTL")" "$identity" || return
    done
    # An identical desired result is still an external edit if it differs from
    # the last managed contents: skipping a write must never bypass that guard.
    printf 'net.core.rmem_max = 16777216\n' > "$SYSCTL"
    cp "$SYSCTL" "$sandbox/external"
    if (write_file "$SYSCTL" < "$sandbox/external"); then
        printf 'Identical desired contents bypassed external-edit protection\n' >&2
        return 1
    fi
    cmp "$sandbox/external" "$SYSCTL" || return
    cmp "$sandbox/original" "$STATE/original$SYSCTL"
}

test_duplicate_sysctls() {
    load_script
    local sandbox="$HARNESS_TMP/duplicate-sysctls" variant
    mkdir -p "$sandbox"
    STATE="$sandbox/state"; SYSCTL="$sandbox/tuned.conf"
    init_state
    printf '# Existing managed value\nnet.core.rmem_max = 4194304\n' | write_file "$SYSCTL" || return
    cp "$SYSCTL" "$sandbox/before"
    cp "$STATE/manifest" "$sandbox/manifest-before"
    # Optional '-' prefixes, whitespace and / notation identify the same key.
    for variant in 'net.core.rmem_max' '-net.core.rmem_max' 'net/core/rmem_max' '-net/core/rmem_max'; do
        if (printf 'net.core.rmem_max = 4194304\n\t%s\t= 8388608\n' "$variant" | write_file "$SYSCTL"); then
            printf 'Accepted duplicate sysctl key: %s\n' "$variant" >&2
            return 1
        fi
        cmp "$sandbox/before" "$SYSCTL" || return
        cmp "$sandbox/before" "$STATE/expected$SYSCTL" || return
        cmp "$sandbox/manifest-before" "$STATE/manifest" || return
    done
    # A failed first write must not acquire or snapshot an unrelated file.
    SYSCTL="$sandbox/never-managed.conf"
    printf 'original user configuration\n' > "$SYSCTL"
    if (printf 'net.core.wmem_max = 1\n-net/core/wmem_max = 2\n' | write_file "$SYSCTL"); then return 1; fi
    assert_eq "$(cat "$SYSCTL")" 'original user configuration' || return
    [[ ! -e $STATE/original$SYSCTL && ! -e $STATE/expected$SYSCTL ]] || return 1
    cmp "$sandbox/manifest-before" "$STATE/manifest" || return
    # Distinct valid keys and commented-out examples remain valid input.
    printf '# net.core.rmem_max = old\n; net/core/rmem_max = old\n-net/core/rmem_max = 1\nnet.core.wmem_max = 2\n' |
        write_file "$SYSCTL"
}

test_snapshot_key_exactness() {
    load_script
    STATE="$HARNESS_TMP/snapshot-key-exactness"
    init_state
    printf 'other.net.core.rmem_max=shadow\nnet.ipv4.test=net.core.wmem_max=shadow\n' > "$STATE/runtime.before"
    sysctl() { [[ $1 == -n ]] || return 1; printf 'original-%s\n' "$2"; }
    local key attempt
    for attempt in 1 2 3; do
        for key in net.core.rmem_max net.core.wmem_max; do save_runtime "$key" || return; done
    done
    assert_eq "$(wc -l < "$STATE/runtime.before")" 4 || return
    grep -Fxq 'net.core.rmem_max=original-net.core.rmem_max' "$STATE/runtime.before" || return
    grep -Fxq 'net.core.wmem_max=original-net.core.wmem_max' "$STATE/runtime.before" || return
    # Later runtime values cannot replace the very first captured value.
    sysctl() { printf 'modified\n'; }
    for key in net.core.rmem_max net.core.wmem_max; do save_runtime "$key" || return; done
    assert_eq "$(wc -l < "$STATE/runtime.before")" 4 || return
    grep -Fxq 'net.core.rmem_max=original-net.core.rmem_max' "$STATE/runtime.before" || return
    grep -Fxq 'net.core.wmem_max=original-net.core.wmem_max' "$STATE/runtime.before"
}

test_pam_module_detection() {
    load_script
    local fixture="$HARNESS_TMP/pam-module" line
    for line in \
        'session required pam_limits.so' \
        '-session required pam_limits.so # valid optional type' \
        'session [success=1 default=ignore] pam_limits.so' \
        'session required /lib/security/pam_limits.so conf=/etc/security/limits.conf'; do
        printf '%s\n' "$line" > "$fixture"
        pam_limits_present "$fixture" || { printf 'Missed active PAM rule: %s\n' "$line" >&2; return 1; }
    done
    for line in \
        '# session required pam_limits.so' \
        'auth required pam_limits.so' \
        'session required pam_unix.so # pam_limits.so' \
        'session optional pam_exec.so /bin/echo pam_limits.so' \
        'session required pam_limits.so.disabled'; do
        printf '%s\n' "$line" > "$fixture"
        if pam_limits_present "$fixture"; then printf 'False positive PAM rule: %s\n' "$line" >&2; return 1; fi
    done
}

test_sysctl_separator_rules() {
    load_script
    local fixture="$HARNESS_TMP/sysctl-separators"
    printf 'net.ipv4.conf.eth0/100.forwarding = 1\nnet/ipv4/conf/eth0.100/forwarding = 0\n' > "$fixture"
    if validate_sysctl_file "$fixture"; then
        printf 'Missed identical sysctl key with literal interface-name dot\n' >&2
        return 1
    fi
    printf 'net.ipv4.conf.eth0/100.forwarding = 1\nnet.ipv4.conf.eth0.100.forwarding = 0\n' > "$fixture"
    validate_sysctl_file "$fixture"
}

test_queue_duplicate_guard() {
    load_script
    STATE="$HARNESS_TMP/queue-duplicate/state"; SYSCTL="$HARNESS_TMP/queue-duplicate.conf"
    printf 'net.core.rmem_max = 1\n-net/core/rmem_max = 2\n-net.core.default_qdisc = fq\n' > "$SYSCTL"
    local sentinel="$HARNESS_TMP/queue-mutated"
    cp "$SYSCTL" "$HARNESS_TMP/queue-before"
    QDISC=cake
    init_state() { touch "$sentinel"; return 1; }
    track_file() { touch "$sentinel"; return 1; }
    write_file() { touch "$sentinel"; return 1; }
    modprobe() { touch "$sentinel"; return 1; }
    tc() { touch "$sentinel"; return 1; }
    sysctl() { touch "$sentinel"; return 1; }
    if (switch_queue); then printf 'Queue switch accepted duplicate sysctls\n' >&2; return 1; fi
    [[ ! -e $sentinel && ! -d $STATE ]] || return 1
    cmp "$SYSCTL" "$HARNESS_TMP/queue-before"
}

test_memory() {
    load_script
    assert_eq "$(tcp_memory_plan 1024 4096)" '16384 32768 65536' || return
    assert_eq "$(tcp_memory_plan 1024 65536)" '1024 2048 4096' || return
    assert_eq "$(tcp_memory_plan 8192 4096)" '131072 262144 524288' || return
    local page ram low pressure high cap expected pages previous
    for page in 4096 16384 65536; do
        PAGE_SIZE=$page
        previous=0
        for ram in 1 31 32 63 64 127 128 129 255 256 511 512 1023 1024 2048 4096 8191 8192 16384 1048576; do
            read -r low pressure high < <(tcp_memory_plan "$ram" "$page")
            pages=$((ram*1048576/page))
            assert_eq "$low $pressure $high" "$((pages/16)) $((pages/8)) $((pages/4))" || return
            cap=$(smart_memory_cap_mib "$ram")
            expected=$((high*page/8/1048576))
            ((expected <= 256)) || expected=256
            assert_eq "$cap" "$expected" || return
            ((cap >= previous && cap <= 256 && cap*1048576 <= high*page/8)) || return 1
            previous=$cap
        done
    done
}

test_bdp() {
    load_script
    PAGE_SIZE=4096
    # Decimal bandwidth is Mbit/s; BDP is binary MiB.
    assert_eq "$(smart_buffer_plan 500 100 bdp 1024)" '14 32 14 5.960464' || return
    assert_eq "$(smart_buffer_plan 1000 200 bdp 512)" '16 16 50 23.841858' || return
    assert_eq "$(smart_buffer_plan 100000 5000 bdp 8192)" '256 256 119212 59604.644775' || return
    assert_eq "$(smart_buffer_plan 0.001 0.001 bdp 128)" '4 4 4 0.000000' || return
    assert_eq "$(smart_buffer_plan 100 100 bdp 64)" '2 2 5 1.192093' || return
    assert_eq "$(smart_buffer_plan 83.88608 100 bdp 1024)" '4 32 4 1.000000' || return
    assert_eq "$(smart_buffer_plan 83.886081 100 bdp 1024)" '5 32 5 1.000000' || return
    local ram bw rtt chosen cap wanted bdp previous
    for ram in 128 1024 8192; do
        for rtt in 10 100 1000; do
            previous=0
            for bw in 1 100 499 500 1000 10000 100000; do
                read -r chosen cap wanted bdp < <(smart_buffer_plan "$bw" "$rtt" bdp "$ram")
                ((chosen >= previous && chosen <= cap && chosen <= wanted && wanted >= 4)) || return 1
                previous=$chosen
            done
        done
    done
    assert_eq "$(smart_buffer_plan 500 0 asia 4096)" '12 128 12 0.000000' || return
    assert_eq "$(smart_buffer_plan 500 0 overseas 4096)" '48 128 48 0.000000'
}

parse_raw() { (load_script; parse_args "$@") >"$HARNESS_TMP/parse.log" 2>&1; }
parse_ok() {
    parse_raw "$@" && return 0
    printf 'Unexpected rejection: %s\n' "$*" >&2
    cat "$HARNESS_TMP/parse.log" >&2
    return 1
}
parse_bad() {
    if parse_raw "$@"; then printf 'Unexpected acceptance: %s\n' "$*" >&2; return 1; fi
}

test_args() {
    parse_ok apply --kernel skip --buffer-mib 4 || return
    parse_ok apply --kernel skip --buffer-mib 5 || return
    parse_ok apply --kernel skip --buffer-mib 256 || return
    parse_ok apply --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --dry-run || return
    parse_ok apply --smart-bandwidth --bandwidth-mbps 1000 --smart-profile overseas-bdp --dry-run || return
    parse_ok queue --qdisc cake --dry-run || return
    parse_ok rollback --dry-run || return
    parse_bad apply --buffer-mib 3 || return
    parse_bad apply --buffer-mib 257 || return
    parse_bad apply --buffer-mib 04 || return
    parse_bad apply --buffer-mib 8.5 || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 500 || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --buffer-mib 8 || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 0 || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 100001 --rtt-ms 100 || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --speedtest-json file || return
    parse_bad apply --smart-bandwidth --bandwidth-mbps 500 --auto-rtt --dry-run || return
    parse_bad apply --smart-bandwidth --speedtest --rtt-ms 100 --accept-speedtest-terms --dry-run || return
    parse_bad apply --container-test --reboot || return
    parse_bad queue || return
    parse_ok apply --qdisc fq || return
    parse_bad apply --buffer-mib || return
}

test_shape_args() {
    parse_ok shape --rate-mbps 530 --dry-run || return
    parse_ok shape --off --dry-run || return
    parse_ok sweep --peer 192.0.2.1 --nominal-mbps 500 --dry-run || return
    parse_ok sweep --peer my-authorized-peer.example --nominal-mbps 500 --accept-traffic || return
    parse_bad shape --rate-mbps 0 || return
    parse_bad shape --rate-mbps 100001 || return
    parse_bad shape --rate-mbps 530.5 || return
    parse_bad shape --rate-mbps 530 --off || return
    parse_bad apply --rate-mbps 530 || return
    parse_bad shape --rate-mbps 530 --accept-traffic || return
    parse_bad sweep --peer 192.0.2.1 --nominal-mbps 500 || return
    parse_bad sweep --peer -evil --nominal-mbps 500 --dry-run || return
    parse_bad sweep --peer 'host;id' --nominal-mbps 500 --dry-run || return
    parse_bad sweep --peer 192.0.2.1 --nominal-mbps 10001 --dry-run || return
    parse_bad sweep --peer 192.0.2.1 --nominal-mbps 500 --container-test --dry-run || return
}

test_sweep_model() {
    local model=$1
    load_script
    STATE="$HARNESS_TMP/sweep-$model"
    SWEEP_PEER=authorized.example; SWEEP_ADDRESS=192.0.2.1; SWEEP_NOMINAL=500
    SHAPE_IFACE=test0; SHAPE_SAMPLE_COUNT=0
    shape_put_fq() { :; }
    shape_put_rate() { :; }
    shape_verify_rate() { :; }
    sleep() { :; }
    # Deterministic experiment fixtures: tests exercise real scan/validation
    # decisions while all network traffic and queue changes are mocked.
    shape_sample() {
        local label=$1 rate=$2
        SHAPE_SAMPLE_COUNT=$((SHAPE_SAMPLE_COUNT+1))
        ((SHAPE_SAMPLE_COUNT <= 28)) || return 1
        if [[ $rate == unshaped ]]; then
            SHAPE_SAMPLE_GOODPUT=480; SHAPE_SAMPLE_RATIO=3
            if [[ $model == low ]]; then SHAPE_SAMPLE_RATIO=.01; fi
            if [[ $model == unstable && $label == baseline-repeat ]]; then SHAPE_SAMPLE_GOODPUT=300; fi
        else
            SHAPE_SAMPLE_GOODPUT=$(awk -v rate="$rate" 'BEGIN{g=rate*.98;print g<499?g:499}')
            SHAPE_SAMPLE_RATIO=.01
            if ((rate > 530)) && [[ $model != no-bracket ]]; then SHAPE_SAMPLE_RATIO=3; fi
            if [[ $model == regression && $label == validate-* ]]; then SHAPE_SAMPLE_GOODPUT=400; fi
        fi
    }
    shape_run_sweep || return
    case $model in
        low)
            grep -Fxq 'status=low-retransmissions' "$SHAPE_LOG_DIR/result.txt" || return
            assert_eq "$SHAPE_SAMPLE_COUNT" 1 || return ;;
        unstable)
            grep -Fxq 'status=inconclusive-baseline' "$SHAPE_LOG_DIR/result.txt" || return
            assert_eq "$SHAPE_SAMPLE_COUNT" 2 || return ;;
        no-bracket) grep -Fxq 'status=no-bracket' "$SHAPE_LOG_DIR/result.txt" || return ;;
        regression) grep -Fxq 'status=inconclusive-validation' "$SHAPE_LOG_DIR/result.txt" || return ;;
        valid)
            grep -Fxq 'status=validated-suggestion' "$SHAPE_LOG_DIR/result.txt" || return
            local suggestion
            suggestion=$(awk -F= '$1=="rate_mbps"{print $2}' "$SHAPE_LOG_DIR/result.txt")
            ((suggestion >= 500 && suggestion < 530)) || return 1 ;;
    esac
    [[ ! -f $STATE/shaping/active ]] || return 1
}

# Stub only the host reads needed by choose_plan, retaining its real algorithm.
mock_plan_reads() {
    awk() {
        if [[ ${*: -1} == /proc/meminfo ]]; then printf '%s\n' "${TEST_RAM:-1024}"; else command awk "$@"; fi
    }
    getconf() { printf '%s\n' "${TEST_PAGE:-4096}"; }
    cat() {
        case ${1:-} in
            /proc/sys/fs/file-max) printf '9223372036854775807\n' ;;
            /proc/sys/fs/nr_open) printf '1048576\n' ;;
            *) command cat "$@" ;;
        esac
    }
}

test_choose() {
    load_script
    mock_plan_reads
    KERNEL=skip; SMART=1; BANDWIDTH=500; RTT_MS=100
    TEST_RAM=1024; TEST_PAGE=65536
    choose_plan
    assert_eq "$BUFFER $TCP_MEM $PAGE_SIZE" '14 1024 2048 4096 65536' || return
    SMART=0; BUFFER=32; TEST_RAM=1024
    choose_plan
    assert_eq "$BUFFER" 32 || return
    if (BUFFER=33; choose_plan); then return 1; fi
    TEST_RAM=64; BUFFER=auto
    choose_plan
    assert_eq "$BUFFER" 2 || return
    if (TEST_RAM=31; BUFFER=auto; choose_plan); then return 1; fi
    SMART=1; SMART_CAP_MIB=32; BUFFER=14
    set_smart_buffer 32 || return
    assert_eq "$BUFFER" 32 || return
    if set_smart_buffer 33; then return 1; fi
    if set_smart_buffer 0; then return 1; fi
    if set_smart_buffer 257; then return 1; fi
}

test_dry() {
    load_script
    mock_plan_reads
    local sentinel="$HARNESS_TMP/dry-mutated"
    check_os() { VERSION_ID=13; CODENAME=trixie; }
    configured_qdisc() { echo fq; }
    init_state() { touch "$sentinel"; return 1; }
    write_file() { touch "$sentinel"; return 1; }
    sysctl() { touch "$sentinel"; return 1; }
    modprobe() { touch "$sentinel"; return 1; }
    tc() { touch "$sentinel"; return 1; }
    apt_update() { touch "$sentinel"; return 1; }
    apt_install() { touch "$sentinel"; return 1; }
    # main intentionally requires Linux root. Git Bash uses a non-root EUID;
    # test equivalent plan path there, and full main in isolated Docker.
    if ((EUID == 0)); then
        main apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --dry-run || return
    else
        check_os
        parse_args apply --kernel skip --smart-bandwidth --bandwidth-mbps 500 --rtt-ms 100 --dry-run
        resolve_rtt; resolve_bandwidth; choose_plan; show_tuning_plan
    fi
    [[ ! -e $sentinel && $BUFFER == 14 ]] || return 1
}

test_active_shaping_apply_guard() {
    load_script
    ((EUID == 0)) || { printf 'Main root guard is exercised by the Docker run\n'; return 0; }
    STATE="$HARNESS_TMP/active-guard"
    mkdir -p "$STATE/shaping"
    printf 'test0 530\n' > "$STATE/shaping/active"
    check_os() { VERSION_ID=13; CODENAME=trixie; }
    configured_qdisc() { printf 'cake\n'; }
    local sentinel="$STATE/reached-plan"
    choose_plan() { touch "$sentinel"; }
    if (main apply --kernel skip --dry-run); then
        printf 'Apply accepted incompatible default qdisc with active shaping\n' >&2
        return 1
    fi
    [[ ! -f $sentinel ]]
}

test_snapshot_rollback() {
    local failure_mode=${1:-sysctl}
    load_script
    mock_plan_reads
    KERNEL=skip; QDISC=fq
    choose_plan
    local sandbox="$HARNESS_TMP/rollback-$failure_mode" key line expected count archived
    mkdir -p "$sandbox"
    STATE="$sandbox/state"
    SYSCTL="$sandbox/tuned.conf"
    printf 'original-config\n' > "$SYSCTL"
    init_state
    # Only this path is redirected: all manifest/backup logic remains real.
    eval "$(declare -f write_file | sed '1s/write_file/real_write_file/')"
    write_file() {
        local dest=$1
        [[ $dest != /etc/* ]] || dest="$sandbox$dest"
        real_write_file "$dest"
    }
    configure_network
    grep -Fxq 'net.ipv4.tcp_mem = 16384 32768 65536' "$SYSCTL" || return
    grep -Fxq 'net.ipv4.tcp_slow_start_after_idle = 0' "$SYSCTL" || return
    grep -Fxq -- '-net.core.default_qdisc = fq' "$SYSCTL" || return
    expected="$sandbox/original-values"
    : > "$expected"
    while IFS= read -r line; do
        [[ $line == *=* && $line != \#* ]] || continue
        key=${line%%=*}; key=${key// /}; key=${key#-}
        printf '%s=original-%s\n' "$key" "$key" >> "$expected"
    done < "$SYSCTL"
    cp "$expected" "$sandbox/live-values"
    count=$(wc -l < "$expected")
    ((count >= 20)) || return 1
    sysctl() {
        local key value
        case $1 in
            -n)
                key=$2
                command awk -v key="$key" 'index($0,key"=")==1 {print substr($0,length(key)+2);found=1;exit} END{exit !found}' "$sandbox/live-values" ;;
            -w)
                key=${2%%=*}; value=${2#*=}
                if [[ -f $sandbox/fail-next-restore && $value == original-* ]]; then
                    rm "$sandbox/fail-next-restore"
                    return 1
                fi
                command awk -v key="$key" 'index($0,key"=")!=1' "$sandbox/live-values" > "$sandbox/next"
                printf '%s=%s\n' "$key" "$value" >> "$sandbox/next"
                mv "$sandbox/next" "$sandbox/live-values" ;;
            *) return 1 ;;
        esac
    }
    modprobe() { :; }
    systemctl() {
        if [[ -f $sandbox/fail-next-service && $1 == daemon-reload ]]; then
            rm "$sandbox/fail-next-service"
            return 1
        fi
    }
    shape_rollback() { :; }
    tc() { printf 'ERROR: unexpected real queue path\n' >&2; return 1; }
    apply_runtime
    assert_eq "$(wc -l < "$STATE/runtime.before")" "$count" || return
    cmp "$expected" "$STATE/runtime.before" || return
    configure_network
    apply_runtime
    cmp "$expected" "$STATE/runtime.before" || return
    # Dry rollback must preserve both disk configuration and the snapshot.
    DRY=1; rollback
    [[ -f $SYSCTL && -d $STATE ]] || return 1
    DRY=0
    if [[ $failure_mode == sysctl ]]; then touch "$sandbox/fail-next-restore"
    else touch "$sandbox/fail-next-service"; fi
    if (rollback); then printf 'rollback ignored a failed sysctl restore\n' >&2; return 1; fi
    [[ -d $STATE ]] || return 1
    assert_eq "$(cat "$SYSCTL")" original-config || return
    # A recreated file after partial rollback belongs to the user and must survive.
    printf 'external-recreated-file\n' > "$sandbox/etc/modules-load.d/90-vps-tune.conf"
    if (rollback); then printf 'rollback deleted a file recreated after partial restore\n' >&2; return 1; fi
    assert_eq "$(cat "$sandbox/etc/modules-load.d/90-vps-tune.conf")" external-recreated-file || return
    rm "$sandbox/etc/modules-load.d/90-vps-tune.conf"
    # A second rollback must work after persistent files were already restored.
    rollback
    [[ ! -d $STATE && ! -e $sandbox/etc/modules-load.d/90-vps-tune.conf ]] || return 1
    assert_eq "$(cat "$SYSCTL")" original-config || return
    sort "$expected" > "$sandbox/expected-sorted"
    sort "$sandbox/live-values" > "$sandbox/live-sorted"
    cmp "$sandbox/expected-sorted" "$sandbox/live-sorted" || return
    archived=$(find "$sandbox" -maxdepth 1 -type d -name 'state.rolled-back.*')
    [[ -n $archived && -f $archived/runtime.before ]] || return 1
}

case_run 'Bash syntax' bash -n "$SCRIPT"
case_run 'Idempotency: unchanged writes preserve identity and first snapshots' test_write_idempotence
case_run 'Idempotency: duplicate normalized sysctl keys fail before mutation' test_duplicate_sysctls
case_run 'Idempotency: runtime snapshots match exact keys and preserve first values' test_snapshot_key_exactness
case_run 'Idempotency: PAM module detection respects comments and valid controls' test_pam_module_detection
case_run 'Idempotency: sysctl separator rules preserve literal interface-name dots' test_sysctl_separator_rules
case_run 'Idempotency: queue duplicates fail before live changes or snapshots' test_queue_duplicate_guard
case_run 'TCP budget: exact page-size and memory boundaries' test_memory
case_run 'BDP: examples, rounding boundaries, monotonicity, legacy profiles' test_bdp
case_run 'CLI accepts existing forms and rejects invalid/conflicting inputs' test_args
case_run 'Shape/sweep argument validation and traffic consent' test_shape_args
case_run 'Plan and manual buffer honor page size and cap' test_choose
case_run 'Dry-run never calls mutation functions' test_dry
case_run 'Apply rejects incompatible queue while shaping is active' test_active_shaping_apply_guard
case_run 'Every emitted sysctl is snapshotted once and rolled back' test_snapshot_rollback
case_run 'Service failure after file restoration is retryable' test_snapshot_rollback service
case_run 'Sweep low retransmission baseline exits after one sample' test_sweep_model low
case_run 'Sweep unstable baselines yield no recommendation' test_sweep_model unstable
case_run 'Sweep with no repeatable boundary yields no recommendation' test_sweep_model no-bracket
case_run 'Sweep rejects lower-throughput validation' test_sweep_model regression
case_run 'Sweep repeatable boundary produces only a bounded suggestion' test_sweep_model valid
printf '\n%s passed; %s failed\n' "$passed" "$failed"
((failed == 0))
