#!/usr/bin/env bash
# Real tc transactions, only in a disposable Docker --network none container
# with --cap-add NET_ADMIN. All systemctl/sysctl/modprobe calls are mocked.
# VPS_TUNE_TCPFIT_TEST=1 bash tests/integration-tcpfit-migration.sh [script]
# Optional VPS_TUNE_TEST_JQ names an existing jq executable; no downloads occur.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
if [[ ${VPS_TUNE_TCPFIT_TEST:-0} != 1 || ! -f /.dockerenv ]]; then
    printf 'SKIP: explicitly opt in inside Docker --network none --cap-add NET_ADMIN.\n'
    exit 0
fi
((EUID == 0)) || { printf 'Disposable container root required.\n' >&2; exit 1; }
[[ -z $(ip -4 route show default) && -z $(ip -6 route show default) ]] || {
    printf 'Refusing a container with an existing default route; use --network none.\n' >&2; exit 1;
}
SCRIPT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/vps-tune.sh}
TEST_ROOT=$(mktemp -d /tmp/tcpfit-migration-integration.XXXXXXXX)
for owned_path in /usr/local/sbin/tcpfit-qdisc.sh /etc/systemd/system/tcpfit-qdisc.service /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service; do
    [[ ! -e $owned_path && ! -L $owned_path ]] || { printf 'Refusing existing fixture path: %s\n' "$owned_path" >&2; exit 1; }
done
cleanup_test() {
    local rc=$?
    trap - EXIT
    ip link del test0 2>/dev/null || true
    rm -f -- /usr/local/sbin/tcpfit-qdisc.sh /etc/systemd/system/tcpfit-qdisc.service /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service
    if ((rc)); then printf 'Preserved failure artifacts: %s\n' "$TEST_ROOT" >&2
    else rm -rf -- "$TEST_ROOT"; fi
    exit "$rc"
}
trap cleanup_test EXIT
ip link add test0 type dummy
ip addr add 198.18.0.1/24 dev test0
ip link set test0 up
ip route add default dev test0

write_tcpfit_fixture() {
    # Literal write_qdisc heredoc from the referenced tcpfit.sh, with only
    # iface=test0 and rate=1037 substituted. No downloaded script is executed.
    cat > "$TCPFIT_HELPER" <<'EOF'
#!/bin/bash
IF=${TCPFIT_IF:-}
[ -n "$IF" ] || IF=$(ip -o -4 route show default 2>/dev/null | head -1 |
      awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$IF" ] || IF=test0
RATE=${1:-1037}
BURST=$(awk -v r="$RATE" 'BEGIN{v=r*500; if(v<32768)v=32768; printf "%d",v}')
if ! tc qdisc del dev $IF root 2>/dev/null; then
  case "$(tc qdisc show dev $IF 2>/dev/null | head -1)" in
    *" mq "*) tc qdisc replace dev $IF root handle 1: mq 2>/dev/null &&
              tc qdisc del dev $IF root 2>/dev/null ;;
  esac
fi
tc qdisc replace dev $IF root handle 1: htb default 10 || exit 1
tc class replace dev $IF parent 1: classid 1:10 htb rate ${RATE}mbit ceil ${RATE}mbit burst ${BURST} cburst ${BURST} quantum 1514 || exit 1
tc qdisc replace dev $IF parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate ${RATE}mbit || exit 1
EOF
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
    chmod 755 "$TCPFIT_HELPER"
    chmod 644 "$TCPFIT_UNIT"
    cp -a "$TCPFIT_HELPER" "$CASE_DIR/original.helper"
    cp -a "$TCPFIT_UNIT" "$CASE_DIR/original.unit"
    bash "$TCPFIT_HELPER" 1037
}

run_case() (
    local case_name=$1 rc original_signature
    # shellcheck source=/dev/null
    source "$SCRIPT"
    trap - EXIT ERR INT TERM
    CASE_DIR=$TEST_ROOT/$case_name
    STATE=$CASE_DIR/state
    TMP=$CASE_DIR/tmp
    mkdir -p "$TMP" "$CASE_DIR/mocksvc" /etc/systemd/system /usr/local/sbin
    if ! command -v jq >/dev/null; then
        local jq_source=${VPS_TUNE_TEST_JQ:-/work/tools/jq-linux-amd64}
        [[ -x $jq_source ]] || { printf 'Supply jq through VPS_TUNE_TEST_JQ.\n' >&2; exit 1; }
        mkdir "$CASE_DIR/bin"
        ln -s "$jq_source" "$CASE_DIR/bin/jq"
        PATH=$CASE_DIR/bin:$PATH
        export PATH
    fi
    preflight() { :; }
    modprobe() { printf '%s\n' "$*" >> "$CASE_DIR/modprobe.mock"; }
    sysctl() {
        printf '%s\n' "$*" >> "$CASE_DIR/sysctl.mock"
        [[ $1 != -n ]] || printf 'fq\n'
    }
    getent() { [[ $1 == ahosts ]] || return 1; printf '198.18.0.2 STREAM test-peer\n'; }
    iperf3() { printf 'Unexpected real scan invocation\n' >&2; return 99; }
    systemctl() {
        local action=$1 unit=${*: -1} property=${3:-} item
        printf '%s\n' "$*" >> "$CASE_DIR/systemctl.mock"
        case $action in
            show)
                case $property in
                    FragmentPath) printf '%s\n' "$TCPFIT_UNIT" ;;
                    DropInPaths) : ;;
                    NeedDaemonReload) printf 'no\n' ;;
                    UnitFileState) cat "$CASE_DIR/mocksvc/$unit.enabled" ;;
                    ActiveState) cat "$CASE_DIR/mocksvc/$unit.active" ;;
                    *) return 1 ;;
                esac ;;
            is-enabled)
                [[ -f $CASE_DIR/mocksvc/$unit.enabled && $(cat "$CASE_DIR/mocksvc/$unit.enabled") == enabled ]] ;;
            enable)
                if [[ $unit == vps-tune-shape.service && -f $CASE_DIR/fail-enable ]]; then
                    rm "$CASE_DIR/fail-enable"; return 1
                fi
                printf 'enabled\n' > "$CASE_DIR/mocksvc/$unit.enabled" ;;
            disable)
                printf 'disabled\n' > "$CASE_DIR/mocksvc/$unit.enabled"
                for item in "$@"; do [[ $item != --now ]] || printf 'inactive\n' > "$CASE_DIR/mocksvc/$unit.active"; done ;;
            start)
                [[ $unit != tcpfit-qdisc.service ]] || bash "$TCPFIT_HELPER" 1037
                printf 'active\n' > "$CASE_DIR/mocksvc/$unit.active" ;;
            stop) printf 'inactive\n' > "$CASE_DIR/mocksvc/$unit.active" ;;
            daemon-reload)
                if [[ -f $CASE_DIR/kill-pending && $(tcpfit_migration_state) == pending && ! -f $TCPFIT_HELPER ]]; then
                    rm "$CASE_DIR/kill-pending"
                    kill -KILL "$BASHPID"
                fi ;;
            daemon-reexec) : ;;
            *) printf 'Unexpected systemctl operation: %s\n' "$*" >&2; return 1 ;;
        esac
    }
    printf 'enabled\n' > "$CASE_DIR/mocksvc/tcpfit-qdisc.service.enabled"
    printf 'active\n' > "$CASE_DIR/mocksvc/tcpfit-qdisc.service.active"
    init_state
    printf 'tracked baseline\n' | write_file "$CASE_DIR/base.conf"
    tc qdisc replace dev test0 root handle 7a00: fq limit 12001
    shape_mark_fq test0
    cp "$STATE/shaping/fq.test0" "$CASE_DIR/original.fq-marker"
    write_tcpfit_fixture
    original_signature=$(tcpfit_queue_signature test0)
    tcpfit_migration_preflight test0
    [[ $TCPFIT_MIGRATION_RATE == 1037 && $TCPFIT_MIGRATION_IFACE == test0 ]]

    case $case_name in
        success)
            migrate_tcpfit_shaper
            [[ $(tcpfit_migration_state) == committed ]]
            [[ ! -e $TCPFIT_UNIT && ! -e $TCPFIT_HELPER ]]
            tcpfit_backup_verify
            [[ $(cat "$STATE/shaping/active") == 'test0 1037' ]]
            shape_verify_rate test0 1037
            shape_run_sweep() {
                SHAPE_LOG_DIR=$STATE/sweeps/mock-low-retransmission
                mkdir -p "$SHAPE_LOG_DIR"
                shape_put_fq "$SHAPE_IFACE"
                printf 'status=no-shaping-needed\n' > "$SHAPE_LOG_DIR/result.txt"
            }
            ACTION=sweep; SWEEP_PEER=test-peer; SWEEP_NOMINAL=1000; ACCEPT_TRAFFIC=1
            run_shape_action
            [[ $(cat "$STATE/shaping/active") == 'test0 1037' ]]
            shape_verify_rate test0 1037
            ACTION=shape; SHAPE_OFF=1
            run_shape_action
            [[ ! -e $STATE/shaping/active && $(tcpfit_migration_state) == committed ]]
            [[ $(shape_signature test0) == "$(cat "$STATE/shaping/fq.test0")" ]]
            ;;
        enable-failure|pending-interruption)
            if [[ $case_name == enable-failure ]]; then touch "$CASE_DIR/fail-enable"
            else touch "$CASE_DIR/kill-pending"; fi
            # A direct child shell keeps errexit enabled inside the production
            # transaction; conditional function invocation would disable it.
            set +e
            (set -e; migrate_tcpfit_shaper) > "$CASE_DIR/expected-failure.log" 2>&1
            rc=$?
            set -e
            ((rc != 0))
            if [[ $case_name == enable-failure ]]; then
                [[ $(tcpfit_migration_state) == restored ]]
                [[ $(tcpfit_queue_signature test0) == "$original_signature" ]]
                cmp "$CASE_DIR/original.fq-marker" "$STATE/shaping/fq.test0"
                [[ ! -e $STATE/shaping/active && ! -e /usr/local/sbin/vps-tune-shape && ! -e /etc/systemd/system/vps-tune-shape.service ]]
            else
                [[ $(tcpfit_migration_state) == pending && ! -e $TCPFIT_HELPER && ! -e $TCPFIT_UNIT ]]
                set +e
                (set -e; ACTION=apply; tcpfit_migration_guard) > "$CASE_DIR/pending-guard.log" 2>&1
                rc=$?
                set -e
                ((rc != 0))
            fi ;;
        *) return 1 ;;
    esac
    ACTION=rollback
    rollback
    [[ ! -d $STATE ]]
    local -a archived=("$STATE".rolled-back.*)
    [[ ${#archived[@]} == 1 && $(cat "${archived[0]}/tcpfit-migration/status") == restored ]]
    if [[ $case_name != success ]]; then
        cmp "$CASE_DIR/original.fq-marker" "${archived[0]}/shaping/fq.test0"
    fi
    cmp "$CASE_DIR/original.helper" "$TCPFIT_HELPER"
    cmp "$CASE_DIR/original.unit" "$TCPFIT_UNIT"
    [[ $(tcpfit_queue_signature test0) == "$original_signature" ]]
    [[ $(cat "$CASE_DIR/mocksvc/tcpfit-qdisc.service.enabled") == enabled ]]
    [[ $(cat "$CASE_DIR/mocksvc/tcpfit-qdisc.service.active") == active ]]
    [[ ! -e /usr/local/sbin/vps-tune-shape && ! -e /etc/systemd/system/vps-tune-shape.service ]]
    rm -f -- "$TCPFIT_HELPER" "$TCPFIT_UNIT"
    printf 'PASS tcpfit real queue migration: %s\n' "$case_name"
)

run_case success
run_case enable-failure
run_case pending-interruption
printf 'PASS tcpfit migration, retained cap, shape-off, failure recovery and pending rollback.\n'
