#!/usr/bin/env bash
# Debian 12/13 VPS system tuning for proxy workloads. Run with bash, as root.
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

STATE=/var/lib/vps-tune
TAG=90-vps-tune.conf
SYSCTL=/etc/sysctl.d/99-zz-vps-tune.conf
KEYRING=/etc/apt/keyrings/vps-tune-xanmod.gpg
ACTION=apply
KERNEL=lts
QDISC=fq
QDISC_EXPLICIT=0
CPU=auto
NOFILE=1048576
BUFFER=auto
TEST=0
DRY=0
REBOOT=0
ALLOW_DKMS=0
REVIEW=0
SMART=0
SMART_PROFILE=bdp
BANDWIDTH=
RTT_MS=
RTT_AUTO=0
RTT_SOURCE=
SPEEDTEST=0
SPEEDTEST_JSON=
ACCEPT_SPEEDTEST=0
BANDWIDTH_SOURCE=manual
DOWNLOAD_MBPS=
SMART_CAP_MIB=
PAGE_SIZE=
TCP_MEM=
BUFFER_CAP_MIB=
SMART_WANTED_MIB=
SMART_BDP_MIB=
SMART_AUTO_MIB=
SMART_BUFFER_SOURCE=auto
TMP=
PACKAGE=
JQ_BIN=
SPEEDTEST_ROOT=
SPEEDTEST_CMD=()
SPINNER_PID=
SPEEDTEST_PING=
SPEEDTEST_JITTER=
SPEEDTEST_LOSS=
SPEEDTEST_SERVER=
SHAPE_RATE=
SHAPE_OFF=0
SWEEP_PEER=
SWEEP_NOMINAL=
ACCEPT_TRAFFIC=0

ui_text() {
    local tone=$1 value=$2 code=
    case $tone in
        heading) code='1;36' ;;
        accent) code=36 ;;
        good) code=32 ;;
        warning) code=33 ;;
        error) code=31 ;;
        muted) code=90 ;;
    esac
    if [[ -n $code && -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        printf '\033[%sm%s\033[0m' "$code" "$value"
    else
        printf '%s' "$value"
    fi
}

log() { ui_text accent '[vps-tune]'; printf ' %s\n' "$*"; }
warn() { ui_text warning "[WARNING] $*" >&2; printf '\n' >&2; }
die() { ui_text error "[ERROR] $*" >&2; printf '\n' >&2; exit 1; }
stop_spinner() {
    [[ -n $SPINNER_PID ]] || return 0
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=
    printf '\r\033[K' >&2
}

start_spinner() {
    local message=$1
    stop_spinner
    # Keep redirected logs and basic terminals free of animation/ANSI escapes.
    [[ -t 2 && ${TERM:-dumb} != dumb ]] || return 0
    (
        # A UI worker must never run the parent's temporary-directory cleanup.
        trap - EXIT ERR INT TERM
        # Reap the short foreground sleep before exiting on a stop request.
        trap 'exit 0' TERM
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local index=0 started=$SECONDS
        while true; do
            printf '\r\033[K  %s %s · 已等待 %s 秒' "${frames[index]}" "$message" "$((SECONDS-started))" >&2
            index=$(((index+1) % ${#frames[@]}))
            sleep 0.15
        done
    ) &
    SPINNER_PID=$!
}

print_heading() {
    printf '\n'; ui_text heading "── $1 ──"; printf '\n'
}

format_metric() {
    if [[ -z $1 ]]; then printf '未提供'
    else awk -v value="$1" -v unit="$2" 'BEGIN {printf "%.2f %s", value, unit}'; fi
}

cleanup() { stop_spinner; [[ -z $TMP ]] || rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
on_error() { local rc=$1 line=$2; ui_text error "[ERROR] line $line, exit $rc. Inspect output; backup: $STATE" >&2; printf '\n' >&2; exit "$rc"; }
trap 'on_error "$?" "$LINENO"' ERR

usage() {
    cat <<'EOF'
Usage: bash vps-tune.sh                    # Chinese interactive menu
       bash vps-tune.sh [menu|apply|check|rollback|measure|queue|shape|sweep] [options]
  --review                Show the calculated plan, then ask apply/preview/cancel.
  --kernel lts|main|skip    Default: lts. Debian 12 supports LTS only.
  --qdisc cake|fq|fq_codel Apply default, or queue: switch the live discipline.
                          New installations default to fq; saved choices persist.
  --cpu-level auto|v1|v2|v3  Auto chooses the level supported by EVERY CPU.
  --nofile NUMBER          Global soft/hard limit; 65536..1048576.
  --buffer-mib auto|NUMBER Per-direction ceiling, 4..256 MiB, within RAM budget.
  --smart-bandwidth        Opt in to bandwidth-aware buffers (default: BDP).
  --smart-profile bdp|asia-bdp|overseas-bdp|asia|overseas
                          Region BDP: planning RTT 100/200ms. asia/overseas: tables.
  --bandwidth-mbps NUMBER  Target bottleneck/egress bandwidth, decimal Mbit/s.
  --rtt-ms NUMBER          Representative TCP RTT; alternative to --auto-rtt.
  --auto-rtt               Probe mainland TCP RTT; use P75 of valid site medians.
  --speedtest-json FILE    Import an existing Ookla JSON result (bytes/sec).
  --speedtest              Run a temporary isolated official Ookla CLI once.
  --accept-speedtest-terms Explicitly accept Ookla license/GDPR for this run.
  shape --rate-mbps NUMBER Apply an aggregate egress cap with HTB + fq.
  shape --off             Remove owned shaping; keep base tuning and fq.
  sweep --peer HOST --nominal-mbps NUMBER --accept-traffic
                          Explicit iperf3 scan; prints a recommendation only.
                          Requires iperf3/jq, a server on TCP 5201, and a known
                          single-root fq baseline from queue --qdisc fq.
                          Scanning temporarily affects the entire egress NIC.
  --reboot                Reboot after a successful apply (disconnects SSH).
  --allow-dkms            Proceed despite detected DKMS modules.
  --dry-run               Read-only plan. Does not fetch or install packages.
  --container-test        CONTAINERS ONLY: write files/install packages inside
                          container; skip sysctl writes, modprobe, systemctl,
                          bootloader and reboot. This is NOT a host tune.
  -h, --help              Show this help.
No arguments opens the menu; explicit apply installs XanMod LTS and configures
limits/networking. measure only runs a temporary speed test. Reboot is
required for the kernel and all new process limits. Existing processes retain
their limits. rollback restores tracked configuration; it does not remove any
kernel/packages or automatically reboot. Explicit per-service limits can
override system defaults; verify workloads after restarting/rebooting.
Smart mode needs exactly one bandwidth source: --bandwidth-mbps,
--speedtest-json or --speedtest. It cannot be combined with --buffer-mib.
Real speed tests consume traffic; container tests/dry runs never launch them.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            menu|apply|check|rollback|measure|queue|shape|sweep) ACTION=$1; shift ;;
            --kernel|--cpu-level|--nofile|--buffer-mib|--smart-profile|--bandwidth-mbps|--rtt-ms|--speedtest-json|--qdisc|--rate-mbps|--peer|--nominal-mbps)
                (($# >= 2)) || die "Missing value for $1"
                case $1 in
                    --kernel) KERNEL=$2 ;; --cpu-level) CPU=$2 ;;
                    --nofile) NOFILE=$2 ;; --buffer-mib) BUFFER=$2 ;;
                    --smart-profile) SMART_PROFILE=$2 ;;
                    --bandwidth-mbps) BANDWIDTH=$2 ;;
                    --rtt-ms) RTT_MS=$2 ;;
                    --speedtest-json) SPEEDTEST_JSON=$2 ;;
                    --qdisc) QDISC=$2; QDISC_EXPLICIT=1 ;;
                    --rate-mbps) SHAPE_RATE=$2 ;;
                    --peer) SWEEP_PEER=$2 ;;
                    --nominal-mbps) SWEEP_NOMINAL=$2 ;;
                esac
                shift 2 ;;
            --reboot) REBOOT=1; shift ;;
            --allow-dkms) ALLOW_DKMS=1; shift ;;
            --review) REVIEW=1; shift ;;
            --smart-bandwidth) SMART=1; shift ;;
            --auto-rtt) RTT_AUTO=1; shift ;;
            --speedtest) SPEEDTEST=1; shift ;;
            --accept-speedtest-terms) ACCEPT_SPEEDTEST=1; shift ;;
            --container-test) TEST=1; shift ;;
            --dry-run) DRY=1; shift ;;
            --off) SHAPE_OFF=1; shift ;;
            --accept-traffic) ACCEPT_TRAFFIC=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ $KERNEL =~ ^(lts|main|skip)$ ]] || die 'Invalid --kernel'
    [[ $CPU =~ ^(auto|v1|v2|v3)$ ]] || die 'Invalid --cpu-level'
    if [[ ! $NOFILE =~ ^[1-9][0-9]{4,6}$ ]] || ((NOFILE < 65536 || NOFILE > 1048576)); then die 'Invalid --nofile'; fi
    if [[ $BUFFER != auto ]]; then
        if [[ ! $BUFFER =~ ^[1-9][0-9]{0,2}$ ]] || ((BUFFER < 4 || BUFFER > 256)); then die 'Invalid --buffer-mib: use auto or 4..256'; fi
    fi
    [[ $QDISC =~ ^(cake|fq|fq_codel)$ ]] || die 'Invalid --qdisc'
    if [[ $ACTION == queue ]]; then
        ((QDISC_EXPLICIT)) || die 'queue requires --qdisc cake|fq|fq_codel'
        KERNEL=skip
    elif ((QDISC_EXPLICIT)) && [[ $ACTION != apply ]]; then die '--qdisc is only for apply/queue'; fi
    if ((TEST && REBOOT)); then die 'Container tests cannot reboot'; fi
    if [[ $ACTION != apply ]] && ((REBOOT)); then die 'Reboot flag requires apply'; fi
    if ((REVIEW)) && [[ $ACTION != apply ]]; then die '--review requires apply'; fi
    if [[ $ACTION == measure ]]; then
        if [[ -n $BANDWIDTH || -n $SPEEDTEST_JSON || -n $RTT_MS ]] || ((RTT_AUTO)); then die 'measure only accepts real Speedtest options'; fi
        SMART=1; SPEEDTEST=1; SMART_PROFILE=asia
    fi
    validate_smart_args
    validate_shape_args
}

valid_positive() {
    [[ $1 =~ ^[0-9]{1,6}(\.[0-9]{1,9})?$ ]] || return 1
    awk -v number="$1" -v maximum="$2" 'BEGIN {exit !(number > 0 && number <= maximum)}'
}

validate_smart_args() {
    [[ $SMART_PROFILE =~ ^(bdp|asia-bdp|overseas-bdp|asia|overseas)$ ]] || die 'Invalid --smart-profile'
    if ((SMART == 0)); then
        if [[ -n $BANDWIDTH || -n $RTT_MS || -n $SPEEDTEST_JSON || $SMART_PROFILE != bdp ]] || ((SPEEDTEST || ACCEPT_SPEEDTEST || RTT_AUTO)); then
            die 'Bandwidth options require --smart-bandwidth'
        fi
        return 0
    fi
    [[ $ACTION == apply || $ACTION == measure ]] || die 'Bandwidth options are only for apply/measure'
    if ((RTT_AUTO)); then
        [[ $SMART_PROFILE == bdp && -z $RTT_MS ]] || die '--auto-rtt requires profile bdp and cannot be combined with --rtt-ms'
        ((TEST == 0 && DRY == 0)) || die 'RTT probing is disabled in dry-run/container-test; use manual RTT or a region profile'
    fi
    case $SMART_PROFILE in
        asia-bdp|overseas-bdp)
            [[ -z $RTT_MS ]] || die 'Region BDP supplies a planning RTT; use profile bdp for a custom RTT'
            RTT_MS=100
            [[ $SMART_PROFILE != overseas-bdp ]] || RTT_MS=200 ;;
    esac
    [[ $BUFFER == auto ]] || die 'Choose --smart-bandwidth OR a manual --buffer-mib'
    local sources=$SPEEDTEST
    [[ -z $BANDWIDTH ]] || sources=$((sources + 1))
    [[ -z $SPEEDTEST_JSON ]] || sources=$((sources + 1))
    ((sources == 1)) || die 'Smart mode needs exactly one bandwidth source'
    if [[ -n $BANDWIDTH ]] && ! valid_positive "$BANDWIDTH" 100000; then die 'Bandwidth must be > 0 and <= 100000 Mbit/s'; fi
    if [[ $SMART_PROFILE == bdp && -z $RTT_MS ]] && ((RTT_AUTO == 0)); then die 'BDP mode requires --rtt-ms or --auto-rtt'; fi
    if [[ -n $RTT_MS ]] && ! valid_positive "$RTT_MS" 5000; then die 'RTT must be > 0 and <= 5000 ms'; fi
    if ((SPEEDTEST)); then
        ((TEST == 0 && DRY == 0)) || die 'Real Speedtest is disabled in dry-run/container-test; use manual bandwidth or a JSON file'
        ((ACCEPT_SPEEDTEST)) || die '--speedtest requires --accept-speedtest-terms (Ookla license/GDPR and traffic usage)'
    elif ((ACCEPT_SPEEDTEST)); then
        die '--accept-speedtest-terms only applies to --speedtest'
    fi
}

# Independently implemented from tcpfit's BDP/budget approach (reference main
# 76331588af487a973d3445a1bf8bba7037d566ca). tcp_mem is measured in PAGES,
# socket limits in BYTES. This is a planning heuristic, not an OOM guarantee:
# application buffers, UDP and kernel allocations consume additional memory.
tcp_memory_plan() {
    local memory=$1 page=$2
    awk -v memory="$memory" -v page="$page" 'BEGIN {
        pages=int(memory*1048576/page);
        printf "%.0f %.0f %.0f\n", int(pages/16), int(pages/8), int(pages/4);
    }'
}

smart_memory_cap_mib() {
    local memory=$1 cap
    local -a pages=()
    read -r -a pages < <(tcp_memory_plan "$memory" "${PAGE_SIZE:-4096}")
    cap=$((pages[2] * ${PAGE_SIZE:-4096} / 8 / 1048576))
    ((cap <= 256)) || cap=256
    # Do not apply a 4 MiB floor after the memory cap: that would defeat the
    # budget on tiny machines. choose_plan rejects unusably small budgets.
    printf '%s\n' "$cap"
}

# Emits: chosen_MiB memory_cap_MiB wanted_MiB BDP_MiB.
# Ceil to whole MiB; retain the old region tables as explicit legacy profiles.
smart_buffer_plan() {
    local bandwidth=$1 rtt=${2:-0} profile=$3 memory=$4 cap
    cap=$(smart_memory_cap_mib "$memory")
    awk -v bw="$bandwidth" -v rtt="$rtt" -v mode="$profile" -v cap="$cap" '
    BEGIN {
        bdp=bw*1000000/8*rtt/1000/1048576;
        if (mode=="bdp" || mode=="asia-bdp" || mode=="overseas-bdp") {
            target=2*bdp+2;
            wanted=int(target); if(wanted<target) wanted++;
            if(wanted<4) wanted=4;
        } else if (mode=="asia") {
            wanted=(bw<500 ? 8 : bw<1000 ? 12 : bw<2000 ? 16 : bw<5000 ? 24 : bw<10000 ? 28 : 32);
        } else {
            wanted=(bw<500 ? 16 : bw<1000 ? 48 : 64);
        }
        chosen=(wanted>cap ? cap : wanted);
        printf "%d %d %d %.6f\n", chosen, cap, wanted, bdp;
    }'
}

parse_speedtest_json() {
    local input=$1 result upload_bytes download_bytes
    [[ -f $input && -r $input ]] || die "Cannot read Ookla JSON file: $input"
    # Avoid treating arbitrary large files/streams or JSON strings as measurements.
    (($(stat -c %s -- "$input") <= 1048576)) || die 'Speedtest JSON exceeds 1 MiB'
    result=$("${JQ_BIN:-jq}" -ers '
        if length != 1 then error("Expected exactly one JSON result") else .[0] end |
        if type != "object" or .type != "result" then error("Not an Ookla result") else . end |
        [.upload.bandwidth, .download.bandwidth] |
        if all(.[]; type == "number" and . >= 1 and . <= 12500000000)
        then @tsv else error("Invalid bandwidth in bytes/sec") end' "$input") || die 'Invalid/incomplete Ookla JSON; no guessed bandwidth will be used'
    read -r upload_bytes download_bytes <<< "$result"
    BANDWIDTH=$(awk -v bytes="$upload_bytes" 'BEGIN {printf "%.6f", bytes*8/1000000}')
    DOWNLOAD_MBPS=$(awk -v bytes="$download_bytes" 'BEGIN {printf "%.6f", bytes*8/1000000}')
    valid_positive "$BANDWIDTH" 100000 || die 'Speedtest upload out of range'
    # Optional display fields never participate in the tuning calculation.
    # Remove control/bidi characters from remote text before terminal output.
    # shellcheck disable=SC2016
    result=$("${JQ_BIN:-jq}" -r '
        def metric($limit):
            if type == "number" and . >= 0 and . <= $limit then tostring else "-" end;
        (.ping | if type == "object" then . else {} end) as $ping |
        (.server | if type == "object" then . else {} end) as $server |
        [($ping.latency | metric(60000)), ($ping.jitter | metric(60000)),
         (.packetLoss | metric(100)),
         ([$server.name, $server.location, $server.country] |
          map(select(type == "string" and length > 0)) | join(" · ") |
          gsub("[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]"; " ") |
          .[0:120] | if length == 0 then "未提供" else . end)] | @tsv' "$input") || result=$'-\t-\t-\t未提供'
    IFS=$'\t' read -r SPEEDTEST_PING SPEEDTEST_JITTER SPEEDTEST_LOSS SPEEDTEST_SERVER <<< "$result"
    [[ $SPEEDTEST_PING != - ]] || SPEEDTEST_PING=
    [[ $SPEEDTEST_JITTER != - ]] || SPEEDTEST_JITTER=
    [[ $SPEEDTEST_LOSS != - ]] || SPEEDTEST_LOSS=
    return 0
}

show_speedtest_result() {
    local title='测速结果'
    [[ $BANDWIDTH_SOURCE != ookla-json ]] || title='测速结果（导入 JSON）'
    print_heading "$title"
    printf '  下载速度  %s\n' "$(format_metric "$DOWNLOAD_MBPS" Mbps)"
    printf '  上传速度  %s\n' "$(format_metric "$BANDWIDTH" Mbps)"
    printf '  测速延迟  %s\n' "$(format_metric "$SPEEDTEST_PING" ms)"
    printf '  延迟抖动  %s\n' "$(format_metric "$SPEEDTEST_JITTER" ms)"
    printf '  丢包比例  %s\n' "$(format_metric "$SPEEDTEST_LOSS" '%')"
    printf '  测速节点  %s\n' "${SPEEDTEST_SERVER:-未提供}"
    printf '\n  延迟对应上方测速节点；智能调优使用另行选择的参考 RTT。\n'
}

ensure_tmp() {
    [[ -n $TMP ]] || TMP=$(mktemp -d /tmp/vps-tune.XXXXXXXX)
}

# NodeQuality delegates mainland delay tests to xykt/NetQuality, whose
# province/operator targets use <province>-<ct|cu|cm>-v4.ip.zstaticcdn.com.
# Reference: https://github.com/xykt/NetQuality/tree/d5b99484d51286374d24b892c1b54235dc282148
# This independent lightweight probe measures TCP handshakes, not MTR's
# 1400-byte probes, route hops, one-way latency, or end-user connection RTT.
cn_rtt_targets() {
    printf '%s\n' 'bj CT 北京电信' 'bj CU 北京联通' 'bj CM 北京移动' \
        'sh CT 上海电信' 'sh CU 上海联通' 'sh CM 上海移动' \
        'gd CT 广东电信' 'gd CU 广东联通' 'gd CM 广东移动'
}

cn_site_summary() {
    sort -k2,2n "$1" | awk '
        NF==2 {n++; ip[n]=$1; value[n]=$2}
        END {
            if(!n) exit;
            mid=(n%2 ? value[int(n/2)+1] : (value[n/2]+value[n/2+1])/2);
            printf "%s %.3f %d %.3f\n", ip[int(n/2)+1], mid, n, value[n]-value[1];
        }'
}

probe_cn_sample() {
    local host=$1 metrics address dns connect
    # Disable curlrc/proxies; DNS time is excluded from the TCP interval.
    # HTTP failures after a successful handshake do not erase its RTT.
    metrics=$(curl -q --noproxy '*' -4 -s --head --connect-timeout 2 \
        --max-time 3 -o /dev/null -w '%{remote_ip} %{time_namelookup} %{time_connect}' \
        "http://$host/") || true
    read -r address dns connect <<< "$metrics" || return 0
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    case $address in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;; esac
    [[ $dns =~ ^[0-9]+(\.[0-9]+)?$ && $connect =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    awk -v ip="$address" -v dns="$dns" -v connected="$connect" 'BEGIN {
        rtt=(connected-dns)*1000;
        if (rtt>0 && rtt<=5000) printf "%s %.3f\n", ip, rtt;
    }'
}

probe_cn_site() {
    local host=$1 output=$2 attempt limit=7 result address median count spread
    : > "$output"
    for ((attempt=1; attempt<=limit; attempt++)); do
        ((attempt == 1)) || sleep 0.2
        probe_cn_sample "$host" >> "$output"
        if ((attempt == 7)); then
            result=$(cn_site_summary "$output")
            if [[ -z $result ]]; then
                limit=11
            else
                read -r address median count spread <<< "$result"
                # Retest a range exceeding both 50 ms and half the median.
                # Keep all samples: sustained high RTT must not be hidden.
                if ((count < 5)) || awk -v mid="$median" -v spread="$spread" \
                    'BEGIN {exit !(spread>50 && spread>mid*0.5)}'; then
                    limit=11
                fi
            fi
        fi
    done
    printf '%s\n' "$limit" > "$output.attempts"
}

resolve_rtt() {
    ((RTT_AUTO)) || return 0
    command -v curl >/dev/null || die '大陆 RTT 探测需要已有 curl；也可选择区域参考值或手填 RTT。'
    ensure_tmp
    local directory=$TMP/cn-rtt region isp label host key result address median count spread attempts note
    local successful=0 failed=0 regions=0 provider_count=0 pid
    local -a jobs=()
    local -A seen=() covered_region=() covered_isp=()
    mkdir -p "$directory"
    log '探测北京、上海、广东三网：每点 7 次；波动较大或样本不足时追加 4 次。'
    start_spinner '正在探测大陆三网 RTT'
    while read -r region isp label; do
        host="$region-${isp,,}-v4.ip.zstaticcdn.com"
        probe_cn_site "$host" "$directory/$region-$isp" &
        jobs+=("$!")
    done < <(cn_rtt_targets)
    for pid in "${jobs[@]}"; do wait "$pid" || true; done
    stop_spinner
    print_heading '大陆三网 RTT'
    : > "$directory/medians"
    while read -r region isp label; do
        key=$region-$isp
        attempts=$(<"$directory/$key.attempts")
        result=$(cn_site_summary "$directory/$key")
        address=; median=; count=0; spread=
        if [[ -n $result ]]; then read -r address median count spread <<< "$result"; fi
        note=; if ((attempts > 7)); then note='，含复测'; fi
        if ((count < 5)); then
            printf '  %-12s 样本不足（有效 %s/%s%s，至少需 5 次）\n' "$label" "$count" "$attempts" "$note"
            failed=$((failed + 1)); continue
        fi
        if [[ -n ${seen[$address]:-} ]]; then
            printf '  %-12s %s ms，测点 IP 重复，不重复计权\n' "$label" "$median"
            continue
        fi
        seen[$address]=1; covered_region[$region]=1; covered_isp[$isp]=1
        successful=$((successful + 1))
        printf '%s\n' "$median" >> "$directory/medians"
        printf '  %-12s %s ms（有效 %s/%s%s；%s）\n' "$label" "$median" "$count" "$attempts" "$note" "$address"
    done < <(cn_rtt_targets)
    regions=${#covered_region[@]}; provider_count=${#covered_isp[@]}
    if ((successful < 5 || regions < 2 || provider_count < 3)); then
        die "大陆 RTT 样本覆盖不足（有效 $successful/9，至少需 5 个测点；地区 $regions/3；运营商 $provider_count/3）。请选择区域参考值或手填 RTT。"
    fi
    RTT_MS=$(sort -n "$directory/medians" | awk '
        {v[NR]=$1} END {rank=int((NR*3+3)/4); r=v[rank]; n=int(r); if(n<r) n++; print n}')
    valid_positive "$RTT_MS" 5000 || die 'Invalid measured RTT; no configuration was changed'
    # Sub-millisecond results across these distant regions can be local SYN
    # interception (e.g. a transparent proxy), not the intended mainland path.
    ((RTT_MS >= 2)) || die '跨地区参考 RTT 不足 2 ms，可能测到了透明代理/TUN 入口或异常测点。未采用该结果，请直连重试或选择区域参考值。'
    RTT_SOURCE="cn-tcp-p75-${successful}of9-sites"
    log "大陆参考 RTT=$RTT_MS ms（各测点中位数的 P75，向上取整；$failed 个测点样本不足）。"
    log '这是公开测点的 TCP 往返时间，不能代表每个用户或单独回程时延。'
}

fetch_https() {
    local url=$1 destination=$2
    if command -v curl >/dev/null; then
        curl --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 15 --max-time 120 "$url" -o "$destination"
    elif command -v wget >/dev/null; then
        wget --https-only --timeout=30 --tries=2 -q "$url" -O "$destination"
    else
        die '临时工具下载需要已有 curl 或 wget；本操作不会自动安装系统软件。也可选择手动带宽。'
    fi
}

verify_download() {
    local path=$1 expected=$2 actual
    actual=$(sha256sum -- "$path"); actual=${actual%% *}
    [[ $actual == "$expected" ]] || die "下载校验失败，停止执行：$path"
}

ensure_json_parser() {
    [[ -z $JQ_BIN ]] || return 0
    # Existing jq is only read/executed; no APT/pip install or replacement.
    if command -v jq >/dev/null; then JQ_BIN=$(command -v jq); return 0; fi
    ((DRY == 0)) || die 'JSON dry-run needs an existing jq; use the menu preview to download an isolated temporary parser'
    ensure_tmp
    local arch digest
    case $(uname -m) in
        x86_64) arch=amd64; digest=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
        aarch64) arch=arm64; digest=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
        *) die 'Temporary jq supports amd64/arm64; use manual bandwidth on this architecture' ;;
    esac
    log '临时准备 JSON 解析器；不会安装到系统。'
    fetch_https "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-$arch" "$TMP/jq"
    verify_download "$TMP/jq" "$digest"
    chmod 700 "$TMP/jq"
    JQ_BIN=$TMP/jq
}

prepare_isolated_speedtest() {
    ensure_tmp
    local arch digest runtime_home required
    for required in unshare mount setpriv timeout; do
        command -v "$required" >/dev/null || die "临时测速环境需要 Debian 基础工具 $required；也可选择手动带宽或 JSON。"
    done
    case $(uname -m) in
        x86_64) arch=x86_64; digest=5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7 ;;
        aarch64) arch=aarch64; digest=3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3 ;;
        *) die 'Ookla temporary runtime supports amd64/arm64 only' ;;
    esac
    log '下载并校验 Ookla 1.2.0，建立一次性测速运行环境。'
    fetch_https "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$arch.tgz" "$TMP/ookla.tgz"
    verify_download "$TMP/ookla.tgz" "$digest"
    SPEEDTEST_ROOT=$TMP/speedtest-home
    mkdir -p "$SPEEDTEST_ROOT"
    tar --no-same-owner --no-same-permissions -xzf "$TMP/ookla.tgz" -C "$SPEEDTEST_ROOT" speedtest
    [[ -f $SPEEDTEST_ROOT/speedtest && ! -L $SPEEDTEST_ROOT/speedtest ]] || die 'Unexpected Speedtest archive entry'
    chmod 755 "$SPEEDTEST_ROOT/speedtest"
    # Keep normal /proc, /sys, /dev and system libraries available. A private
    # mount namespace overlays only the home and temporary directories; the
    # caller's environment/home files and host mount table remain unchanged.
    # Unlike a minimal chroot, this retains the OS interfaces used by the CLI.
    runtime_home=${HOME:-}
    [[ $runtime_home == /* && -d $runtime_home && ! -L $runtime_home && $runtime_home != *'/../'* && $runtime_home != */.. && $runtime_home != *$'\n'* ]] || die 'Unsupported home path for the isolated runtime'
    case $runtime_home in /|/tmp|/tmp/*|/var/tmp|/var/tmp/*|/proc|/sys|/dev|/etc|/usr|/run) die 'Unsafe home path for an isolated runtime' ;; esac
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || die 'Existing system CA certificates are required; no packages were installed'
    chown 65534:65534 "$SPEEDTEST_ROOT"
    chmod 700 "$SPEEDTEST_ROOT"
    cat > "$TMP/run-speedtest" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ulimit -c 0
private_home=$1
original_home=$2
shift 2
mount --bind "$private_home" "$original_home"
# These mounts exist only in this child namespace and vanish on exit.
mount -t tmpfs -o nosuid,nodev,noexec,size=32m tmpfs /tmp
if [[ -d /var/tmp && ! -L /var/tmp ]]; then
    mount -t tmpfs -o nosuid,nodev,noexec,size=16m tmpfs /var/tmp
fi
cd "$original_home"
exec setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs \
    "$original_home/speedtest" "$@"
EOF
    SPEEDTEST_CMD=(unshare --mount --propagation private -- bash "$TMP/run-speedtest" "$SPEEDTEST_ROOT" "$runtime_home")
    local version
    if ! version=$(timeout 10 "${SPEEDTEST_CMD[@]}" --version 2>&1); then
        warn "$version"
        die '临时隔离环境无法启动；需要 mount namespace 权限。未回退到系统安装，可选手动带宽或 JSON。'
    fi
    [[ $version == *'Speedtest by Ookla 1.2.0'* ]] || die 'Unexpected isolated Speedtest version'
}

resolve_bandwidth() {
    ((SMART)) || return 0
    [[ -n $BANDWIDTH ]] && return 0
    ensure_json_parser
    if ((SPEEDTEST)); then
        prepare_isolated_speedtest
        log '开始 Ookla 测速（最多 180 秒）；测速服务器的 ping 不作为大陆 RTT。'
        local speedtest_status=0
        start_spinner '正在测速，请稍候'
        { timeout --kill-after=5 180 "${SPEEDTEST_CMD[@]}" --accept-license --accept-gdpr --ca-certificate=/etc/ssl/certs/ca-certificates.crt --progress=no --format=json > "$TMP/speedtest.json"; } 2> "$TMP/speedtest-error.log" || speedtest_status=$?
        stop_spinner
        if ((speedtest_status != 0)); then
            warn "Ookla 退出码=$speedtest_status；系统=$(uname -srmo)；MemAvailable=$(awk '/MemAvailable:/ {print $2 " kB"}' /proc/meminfo)"
            if [[ -s $TMP/speedtest-error.log ]]; then warn "$(tail -n 10 "$TMP/speedtest-error.log")"
            else warn '测速程序未输出错误详情。'; fi
            case $speedtest_status in
                124|137) warn '测速超时或进程被终止；请检查网络连通性与内存。' ;;
                134|139) warn '测速程序异常中止；这不是成功的测速结果，未写入调优配置。' ;;
            esac
            die '测速失败；临时环境将清理。可稍后重试，或选择手动带宽/已有 JSON。'
        fi
        parse_speedtest_json "$TMP/speedtest.json"
        BANDWIDTH_SOURCE=ookla-live
    else
        parse_speedtest_json "$SPEEDTEST_JSON"
        BANDWIDTH_SOURCE=ookla-json
    fi
    if ((DRY == 0)); then show_speedtest_result; fi
}

is_container() {
    [[ -e /.dockerenv || -e /run/.containerenv || -d /proc/vz ]] && return 0
    if command -v systemd-detect-virt >/dev/null; then
        systemd-detect-virt --container --quiet && return 0
    fi
    grep -qaE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup
}

check_os() {
    [[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian && ${VERSION_ID:-} =~ ^(12|13)$ ]] || die 'Only Debian 12/13 is supported'
    CODENAME=bookworm
    [[ $VERSION_ID != 13 ]] || CODENAME=trixie
}

# /proc/cpuinfo reports usable AVX, including OS XSAVE support. Use the minimum
# feature level across all vCPUs; never execute a downloaded CPU detection script.
cpu_level() {
    awk '
    BEGIN { result=3; seen=0 }
    /^flags[ \t]*:/ {
        seen++; delete f; for (i=3;i<=NF;i++) f[$i]=1;
        level=1;
        if (f["cx16"] && f["lahf_lm"] && f["popcnt"] && (f["pni"] || f["sse3"]) && f["ssse3"] && f["sse4_1"] && f["sse4_2"]) {
            level=2;
            if (f["avx"] && f["avx2"] && f["bmi1"] && f["bmi2"] && f["f16c"] && f["fma"] && (f["abm"] || f["lzcnt"]) && f["movbe"] && f["xsave"]) level=3;
        }
        if (level<result) result=level;
    }
    END { print seen ? result : 1 }' "${1:-/proc/cpuinfo}"
}

choose_plan() {
    MEM_MIB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    PAGE_SIZE=$(getconf PAGESIZE)
    [[ $MEM_MIB =~ ^[1-9][0-9]*$ && $PAGE_SIZE =~ ^[1-9][0-9]*$ ]] || die 'Cannot determine RAM/page size'
    TCP_MEM=$(tcp_memory_plan "$MEM_MIB" "$PAGE_SIZE")
    BUFFER_CAP_MIB=$(smart_memory_cap_mib "$MEM_MIB")
    ((BUFFER_CAP_MIB >= 1)) || die 'Insufficient RAM for the TCP memory budget'
    if ((SMART)); then
        read -r BUFFER SMART_CAP_MIB SMART_WANTED_MIB SMART_BDP_MIB < <(smart_buffer_plan "$BANDWIDTH" "$RTT_MS" "$SMART_PROFILE" "$MEM_MIB")
        SMART_AUTO_MIB=$BUFFER
        SMART_BUFFER_SOURCE=auto
    elif [[ $BUFFER == auto ]]; then
        BUFFER=4
        ((MEM_MIB < 1024)) || BUFFER=8
        ((MEM_MIB < 2048)) || BUFFER=16
        ((MEM_MIB < 4096)) || BUFFER=32
        ((BUFFER <= BUFFER_CAP_MIB)) || BUFFER=$BUFFER_CAP_MIB
    elif ((BUFFER > BUFFER_CAP_MIB)); then
        die "Manual buffer ${BUFFER} MiB exceeds TCP budget cap ${BUFFER_CAP_MIB} MiB"
    fi
    BUF_BYTES=$((BUFFER * 1024 * 1024))
    FS_MAX=$(cat /proc/sys/fs/file-max)
    NR_OPEN=$(cat /proc/sys/fs/nr_open)
    ((FS_MAX >= NOFILE * 2)) || FS_MAX=$((NOFILE * 2))
    ((NR_OPEN >= NOFILE)) || NR_OPEN=$NOFILE
    if [[ $KERNEL != skip ]]; then
        [[ $(dpkg --print-architecture) == amd64 ]] || die 'XanMod official packages require amd64; use --kernel skip on ARM'
        [[ $VERSION_ID != 12 || $KERNEL == lts ]] || die 'Debian 12: use --kernel lts'
        local supported selected
        supported=$(cpu_level /proc/cpuinfo)
        selected=$supported
        [[ $CPU == auto ]] || selected=${CPU#v}
        ((selected <= supported)) || die "CPU supports v$supported, requested v$selected"
        [[ $KERNEL != main || $selected != 1 ]] || die 'MAIN needs v2/v3; use LTS for v1'
        local prefix=
        [[ $KERNEL != lts ]] || prefix=lts-
        PACKAGE="linux-xanmod-${prefix}x64v$selected"
    fi
}

preflight() {
    ((EUID == 0)) || die 'Run as root: sudo bash vps-tune.sh'
    if is_container; then
        ((TEST)) || die 'Containers share the host kernel. Use --container-test for isolated tests only'
    else
        ((TEST == 0)) || die '--container-test is only allowed inside a detected container'
        [[ $(cat /proc/1/comm) == systemd ]] || die 'A systemd host is required'
    fi
    if [[ $KERNEL != skip && $TEST == 0 ]]; then
        if ! command -v update-grub >/dev/null || [[ ! -s /boot/grub/grub.cfg ]]; then die 'Automatic boot selection requires an existing GRUB installation. Use --kernel skip for other bootloaders'; fi
        if [[ -d /sys/firmware/efi ]]; then
            local sb found=0
            for sb in /sys/firmware/efi/efivars/SecureBoot-*; do
                [[ -r $sb ]] || continue
                found=1
                [[ $(od -An -t u1 -j 4 -N 1 "$sb" | tr -d ' ') == 0 ]] || die 'Secure Boot is enabled; unsigned XanMod cannot be selected automatically'
            done
            ((found)) || die 'Cannot verify Secure Boot state; refusing automatic kernel switch'
        fi
        if command -v dkms >/dev/null && [[ -n $(dkms status) ]] && ((ALLOW_DKMS == 0)); then
            die 'DKMS modules detected; verify compatibility, then use --allow-dkms'
        fi
        local root_free boot_free
        root_free=$(df -Pm / | awk 'NR==2 {print $4}')
        boot_free=$(df -Pm /boot | awk 'NR==2 {print $4}')
        ((root_free >= 1500 && boot_free >= 500)) || die 'Need at least 1500 MiB free on / and 500 MiB on /boot'
        compgen -G '/boot/vmlinuz-*' >/dev/null || die 'No existing kernel found in /boot'
    fi
}

init_state() {
    install -d -m 700 "$STATE" "$STATE/original" "$STATE/expected" "$STATE/expected-absent"
    touch "$STATE/manifest" "$STATE/runtime.before"
}

track_file() {
    local path=$1
    if grep -Fxq "$path" "$STATE/manifest"; then
        if [[ -f $STATE/expected-absent$path && ( -e $path || -L $path ) ]]; then
            die "Managed path recreated externally after rollback: $path; reconcile before retrying"
        fi
        if [[ -f $STATE/expected$path ]]; then
            if [[ ! -f $path || -L $path ]] || ! cmp -s "$path" "$STATE/expected$path"; then die "Managed file changed externally: $path; back it up/reconcile before reapplying or rolling back"; fi
        fi
        return
    fi
    [[ ! -L $path ]] || die "Refusing to overwrite symlink: $path"
    if [[ -e $path ]]; then
        [[ -f $path ]] || die "Not a regular file: $path"
        mkdir -p "$STATE/original$(dirname "$path")"
        cp -a -- "$path" "$STATE/original$path"
    fi
    printf '%s\n' "$path" >> "$STATE/manifest"
}

write_file() {
    local path=$1 tmpfile
    track_file "$path"
    mkdir -p "$(dirname "$path")" "$STATE/expected$(dirname "$path")"
    tmpfile=$(mktemp "$(dirname "$path")/.vps-tune.XXXXXX")
    cat > "$tmpfile"
    chmod 644 "$tmpfile"
    mv -f -- "$tmpfile" "$path"
    cp -- "$path" "$STATE/expected$path"
    rm -f -- "$STATE/expected-absent$path"
}

apt_update() { apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=120 install "$@"; }

install_kernel() {
    [[ $KERNEL != skip ]] || return 0
    log "Installing official signed-APT package: $PACKAGE ($CODENAME)"
    apt_update
    apt_install ca-certificates curl gnupg kmod procps iproute2 initramfs-tools
    local existing_repo
    existing_repo=$(grep -rlE '^[[:space:]]*(deb[[:space:]]|URIs:).*deb\.xanmod\.org' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -v '/vps-tune-xanmod.list$' || true)
    if [[ -n $existing_repo ]]; then
        log "Reusing existing XanMod source(s): $existing_repo"
    else
    [[ -n $TMP ]] || TMP=$(mktemp -d)
    export GNUPGHOME="$TMP/gnupg"
    install -d -m 700 "$GNUPGHOME"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 20 --max-time 180 https://dl.xanmod.org/archive.key -o "$TMP/archive.key"
    # The official HTTPS key is scoped to this repository via Signed-By.
    gpg --batch --show-keys --with-fingerprint "$TMP/archive.key"
    local fingerprint
    fingerprint=$(gpg --batch --show-keys --with-colons "$TMP/archive.key" | awk -F: '$1=="fpr" {print $10; exit}')
    [[ $fingerprint == D38D7D1DA1349567ADED882D86F7D09EE734E623 ]] || die 'XanMod signing key changed; verify it against the official source before updating this script'
    gpg --batch --yes --dearmor -o "$TMP/archive.gpg" "$TMP/archive.key"
    write_file "$KEYRING" < "$TMP/archive.gpg"
    write_file /etc/apt/sources.list.d/vps-tune-xanmod.list <<EOF
deb [arch=amd64 signed-by=$KEYRING] https://deb.xanmod.org $CODENAME main
EOF
    fi
    write_file /etc/apt/preferences.d/vps-tune-xanmod <<'EOF'
Package: linux-*xanmod*
Pin: origin "deb.xanmod.org"
Pin-Priority: 700

Package: *
Pin: origin "deb.xanmod.org"
Pin-Priority: -1
EOF
    apt_update
    local candidate
    candidate=$(apt-cache policy "$PACKAGE" | awk '/Candidate:/ {print $2}')
    [[ -n $candidate && $candidate != '(none)' ]] || die "Repository has no candidate for $PACKAGE"
    apt-get -s --no-install-recommends install "$PACKAGE"
    apt_install "$PACKAGE"
    dpkg-query -W -f='${Status}\n' "$PACKAGE" | grep -qx 'install ok installed' || die 'Kernel metapackage not fully installed'
    local image_pkg
    image_pkg=$(dpkg-query -W -f='${Depends}\n' "$PACKAGE" | tr ',' '\n' | awk '/linux-image-/ {print $1; exit}')
    [[ $image_pkg == linux-image-*xanmod* ]] || die 'Cannot identify installed image dependency'
    KERNEL_RELEASE=${image_pkg#linux-image-}
    [[ -s /boot/vmlinuz-$KERNEL_RELEASE && -s /boot/initrd.img-$KERNEL_RELEASE ]] || die 'Kernel image/initramfs missing'
    printf '%s\n' "$KERNEL_RELEASE" > "$STATE/kernel-release"
    printf '%s\n' "$PACKAGE" > "$STATE/kernel-package"
    if ((TEST)); then
        warn 'CONTAINER TEST: packages installed; no bootloader selection or boot test performed'
    else
        configure_grub
        update-grub
        grep -Fq "gnulinux-$KERNEL_RELEASE-advanced-" /boot/grub/grub.cfg || die 'GRUB does not contain the selected kernel menu entry'
        # A pre-existing one-shot next_entry would override GRUB_DEFAULT once.
        if command -v grub-editenv >/dev/null && grub-editenv /boot/grub/grubenv list | grep -q '^next_entry='; then
            die 'GRUB has a pending next_entry; clear/review it before rebooting'
        fi
    fi
}

configure_grub() {
    # Generate first, then use IDs emitted by Debian GRUB (no localized titles).
    update-grub
    local entry boot_id submenu
    entry=$(awk -F "'" -v prefix="gnulinux-$KERNEL_RELEASE-advanced-" '/menuentry / {for(i=2;i<=NF;i+=2) if(index($i,prefix)==1) {print $i; exit}}' /boot/grub/grub.cfg)
    [[ -n $entry ]] || die 'Cannot locate the installed XanMod advanced menu entry'
    boot_id=${entry#gnulinux-"$KERNEL_RELEASE"-advanced-}
    [[ $boot_id =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Unrecognized GRUB device ID'
    submenu=
    if grep -Fq "'gnulinux-advanced-$boot_id'" /boot/grub/grub.cfg; then submenu="gnulinux-advanced-$boot_id>"; fi
    write_file /etc/default/grub.d/90-vps-tune.cfg <<EOF
# Evaluated by grub-mkconfig. Follow this metapackage after future APT updates.
# APT unpacks the metapackage before configuring image packages/triggers.
vps_image=\$(dpkg-query -W -f='\${Depends}\\n' '$PACKAGE' 2>/dev/null | tr ',' '\\n' | awk '/linux-image-/ {print \$1; exit}')
vps_release=\${vps_image#linux-image-}
if [ -s "/boot/vmlinuz-\$vps_release" ]; then
    GRUB_DEFAULT="${submenu}gnulinux-\${vps_release}-advanced-$boot_id"
else
    GRUB_DEFAULT='$submenu$entry'
fi
GRUB_SAVEDEFAULT=false
unset vps_image vps_release
EOF
}

configure_limits() {
    write_file /etc/security/limits.d/90-vps-tune.conf <<EOF
# PAM limits for new sessions. Root needs explicit entries.
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF
    local path
    for path in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [[ -f $path ]] || die "Missing PAM stack: $path"
        if ! grep -Eq '^[[:space:]]*session[[:space:]].*pam_limits\.so([[:space:]]|$)' "$path"; then
            local content
            content=$(cat "$path")
            printf '%s\nsession required pam_limits.so # vps-tune\n' "$content" | write_file "$path"
        fi
    done
    for path in /etc/systemd/system.conf.d/$TAG /etc/systemd/user.conf.d/$TAG; do
        write_file "$path" <<EOF
[Manager]
DefaultLimitNOFILE=$NOFILE:$NOFILE
EOF
    done
    # user@.service ensures a fresh user manager can raise its children's limits.
    write_file "/etc/systemd/system/user@.service.d/$TAG" <<EOF
[Service]
LimitNOFILE=$NOFILE:$NOFILE
EOF
}

configured_qdisc() {
    local selected
    selected=$(awk -F= '/^[[:space:]]*-?net\.core\.default_qdisc[[:space:]]*=/ {
        value=$2; sub(/#.*/, "", value); gsub(/[[:space:]]/, "", value)
    } END {print value}' "$SYSCTL" 2>/dev/null) || selected=
    case $selected in cake|fq|fq_codel) printf '%s' "$selected" ;; *) printf fq ;; esac
}

configure_network() {
    local backlog=8192 listen=4096
    ((MEM_MIB < 1024)) || backlog=16384
    ((MEM_MIB < 512)) || listen=8192
    write_file "$SYSCTL" <<EOF
# Managed by vps-tune. Values are ceilings, not preallocated buffers.
# Buffer plan: $(buffer_plan_description)
fs.file-max = $FS_MAX
fs.nr_open = $NR_OPEN
net.core.somaxconn = $listen
net.ipv4.tcp_max_syn_backlog = $backlog
net.core.netdev_max_backlog = $backlog
net.core.rmem_max = $BUF_BYTES
net.core.wmem_max = $BUF_BYTES
net.ipv4.tcp_rmem = 4096 131072 $BUF_BYTES
net.ipv4.tcp_wmem = 4096 16384 $BUF_BYTES
# Global TCP queue budget: RAM 1/16, 1/8, 1/4 in actual kernel pages.
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1
# Optional until the new kernel boots. The sysctl algorithm name is bbr,
# including on XanMod releases carrying BBRv3; it is not named bbr3.
-net.core.default_qdisc = $QDISC
-net.ipv4.tcp_congestion_control = bbr
EOF
    write_file /etc/modules-load.d/90-vps-tune.conf <<EOF
tcp_bbr
sch_$QDISC
EOF
}

buffer_plan_description() {
    if ((SMART)); then
        local basis=${RTT_SOURCE:-manual}
        case $SMART_PROFILE in
            *-bdp) basis='region-planning-not-measured' ;;
            asia|overseas) basis=not-used ;;
        esac
        printf 'smart/%s; source=%s; upload/target=%s Mbit/s; download=%s Mbit/s; RTT=%s ms; RTT-basis=%s; BDP=%s MiB; wanted=%s MiB; RAM-cap=%s MiB; selected=%s MiB; selection=%s; automatic=%s MiB' \
            "$SMART_PROFILE" "$BANDWIDTH_SOURCE" "$BANDWIDTH" "${DOWNLOAD_MBPS:-not-measured}" "${RTT_MS:-not-used}" "$basis" "$SMART_BDP_MIB" "$SMART_WANTED_MIB" "$SMART_CAP_MIB" "$BUFFER" "$SMART_BUFFER_SOURCE" "$SMART_AUTO_MIB"
    else
        printf 'standard; selected=%s MiB; budget-cap=%s MiB' "$BUFFER" "$BUFFER_CAP_MIB"
    fi
}

show_tuning_plan() {
    print_heading '本次优化方案'
    printf '  系统版本  Debian %s · 内存 %s MiB\n' "$VERSION_ID" "$MEM_MIB"
    printf '  内核方案  %s\n' "${PACKAGE:-保留当前内核}"
    printf '  网络配置  BBR + %s\n' "${QDISC^^}"
    printf '  文件句柄  默认每进程上限 %s\n' "$NOFILE"
    printf '  TCP 预算  %s 页（页大小 %s 字节；RAM 的 1/16、1/8、1/4）\n' "$TCP_MEM" "$PAGE_SIZE"
    printf '  缓冲上限  每个 TCP 连接的收/发缓冲各 %s MiB（按需使用）\n' "$BUFFER"
    if ((SMART)); then
        local basis='手动填写' profile='带宽与 RTT 计算'
        case $SMART_PROFILE in
            asia-bdp) basis='亚太区域规划值' ;;
            overseas-bdp) basis='欧美区域规划值' ;;
            asia) profile='亚太带宽经验表' ;;
            overseas) profile='欧美带宽经验表' ;;
        esac
        [[ $RTT_SOURCE != cn-tcp-* ]] || basis='大陆三网实测 P75'
        printf '  调优方式  %s\n' "$profile"
        printf '  参考带宽  %s（出口/上传）\n' "$(format_metric "$BANDWIDTH" Mbps)"
        if [[ $SMART_PROFILE != asia && $SMART_PROFILE != overseas ]]; then
            printf '  参考 RTT  %s（%s）\n' "$(format_metric "$RTT_MS" ms)" "$basis"
        fi
        printf '  计算参考  %s MiB\n' "$SMART_WANTED_MIB"
        printf '  自动建议  %s MiB（自动内存保护上限 %s MiB）\n' "$SMART_AUTO_MIB" "$SMART_CAP_MIB"
        if [[ $SMART_BUFFER_SOURCE == manual ]]; then
            printf '  选择方式  手动指定 %s MiB，已覆盖自动建议\n' "$BUFFER"
        else
            printf '  选择方式  使用自动建议\n'
        fi
    fi
}

show_buffer_notice() {
    ((SMART)) || return 0
    if [[ $SMART_BUFFER_SOURCE == manual ]]; then
        if ((BUFFER > SMART_CAP_MIB)); then
            warn "手动上限 $BUFFER MiB 高于自动内存保护值 $SMART_CAP_MIB MiB；高并发时可能增加内存压力。"
        fi
    elif ((SMART_WANTED_MIB > SMART_CAP_MIB)); then
        warn "计算参考为 $SMART_WANTED_MIB MiB，自动模式按内存建议 $SMART_AUTO_MIB MiB。"
    fi
}

set_smart_buffer() {
    local value=$1
    [[ $value =~ ^[1-9][0-9]{0,2}$ ]] && ((value >= 4 && value <= 256)) || return 1
    ((value <= SMART_CAP_MIB)) || return 1
    BUFFER=$value
    BUF_BYTES=$((BUFFER * 1024 * 1024))
    SMART_BUFFER_SOURCE=manual
}

review_tuning_plan() {
    while true; do
        show_tuning_plan
        show_buffer_notice
        printf '\n1. 应用方案\n2. 仅预览，返回菜单\n'
        if ((SMART && SMART_CAP_MIB >= 4)); then
            printf '3. 手动设置缓冲上限\n4. 恢复自动建议（%s MiB）\n' "$SMART_AUTO_MIB"
        fi
        printf '0. 取消\n'
        menu_read '请选择 [2]：' 2 || return 1
        case $REPLY in
            1) return 0 ;;
            0|2) return 1 ;;
            3)
                ((SMART)) || { printf '无效选择。\n'; continue; }
                ((SMART_CAP_MIB >= 4)) || { printf '本机预算不足 4 MiB，保留自动值。\n'; continue; }
                while true; do
                    menu_read '输入缓冲上限（4～256 MiB，整数；回车保留）：' || return 1
                    [[ -n $REPLY ]] || break
                    if set_smart_buffer "$REPLY"; then break; fi
                    printf '请输入 4～256 的整数，且不超过本机预算 %s MiB。\n' "$SMART_CAP_MIB"
                done ;;
            4)
                ((SMART)) || { printf '无效选择。\n'; continue; }
                BUFFER=$SMART_AUTO_MIB
                BUF_BYTES=$((BUFFER * 1024 * 1024))
                SMART_BUFFER_SOURCE=auto ;;
            *) printf '无效选择，请重新输入。\n' ;;
        esac
    done
}

show_completion() {
    print_heading '优化配置已保存'
    printf '  文件句柄：系统默认上限已更新为 %s。\n' "$NOFILE"
    printf '            现有会话和服务保留原限制，重新登录或重启服务后检查。\n'
    if [[ $KERNEL != skip ]]; then
        printf '  XanMod：内核已安装/更新，重启后请确认已切换到目标版本。\n'
    fi
    printf '  BBR + %s：已写入开机配置，实际网卡队列需重启后检查。\n' "${QDISC^^}"
    printf '\n  下一步：方便时手动重启，重新连接后选择菜单 5 检查生效状态。\n'
    printf '  原配置已备份，可通过菜单 6 回滚。\n'
}

save_runtime() {
    local key=$1 value
    grep -qF "$key=" "$STATE/runtime.before" && return 0
    if value=$(sysctl -n "$key" 2>/dev/null); then
        printf '%s=%s\n' "$key" "$value" >> "$STATE/runtime.before"
    fi
}

apply_runtime() {
    if ((TEST)); then
        warn 'CONTAINER TEST: runtime sysctl/modprobe/systemd skipped; configuration only'
        return 0
    fi
    local line key value optional failed=0
    # Snapshot defaults before loading modules or changing them.
    while IFS= read -r line; do
        [[ $line == *=* && $line != \#* ]] || continue
        key=${line%%=*}; key=${key// /}; key=${key#-}
        save_runtime "$key"
    done < "$SYSCTL"
    modprobe tcp_bbr || warn 'tcp_bbr unavailable in the running kernel; retry after XanMod reboot'
    modprobe "sch_$QDISC" || warn "sch_$QDISC unavailable in the running kernel; retry after XanMod reboot"
    while IFS= read -r line; do
        [[ $line == *=* && $line != \#* ]] || continue
        key=${line%%=*}; key=${key// /}; value=${line#*=}; optional=0
        if [[ $key == -* ]]; then optional=1; key=${key#-}; fi
        if ! sysctl -w "$key=$value"; then
            if ((optional)); then warn "$key pending new kernel/reboot"; else failed=1; fi
        fi
    done < "$SYSCTL"
    ((failed == 0)) || die 'One or more required sysctls failed; configuration remains available for inspection/rollback'
    systemctl daemon-reload
    systemctl daemon-reexec
}

persist_queue_choice() {
    local content modules=/etc/modules-load.d/$TAG
    if [[ -f $SYSCTL ]]; then content=$(cat "$SYSCTL")
    else content='# Managed by vps-tune.'; fi
    awk -v target="$QDISC" '
        /^[[:space:]]*-?net\.core\.default_qdisc[[:space:]]*=/ {
            if(!written) print "-net.core.default_qdisc = " target;
            written=1; next
        }
        {print}
        END {if(!written) print "-net.core.default_qdisc = " target}' <<< "$content" | write_file "$SYSCTL"
    content=
    [[ ! -f $modules ]] || content=$(cat "$modules")
    awk -v target="$QDISC" '
        /^[[:space:]]*sch_(cake|fq|fq_codel)([[:space:]]*(#.*)?)?$/ {next}
        NF {print}
        END {print "sch_" target}' <<< "$content" | write_file "$modules"
}

switch_queue() {
    local interface output root kind parent required current index leaves
    local -a interfaces=() change_interfaces=() change_parents=()
    local -A snapshots=()
    print_heading "切换队列：${QDISC^^}"
    if ((TEST == 0)); then
        for required in ip tc sysctl modprobe; do
            command -v "$required" >/dev/null || die "缺少 $required，请先执行常规调优安装基础工具。"
        done
        mapfile -t interfaces < <({ ip -o -4 route show default; ip -o -6 route show default; } |
            awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
        ((${#interfaces[@]})) || die '未找到默认路由网卡，未修改配置。'
        # Inspect every interface before making any changes. Complex shaping
        # hierarchies and rate-limited CAKE need a separate migration plan.
        for interface in "${interfaces[@]}"; do
            [[ $interface != */* && $interface != . && $interface != .. ]] || die 'Invalid interface name'
            output=$(tc qdisc show dev "$interface") || die "无法读取 $interface 的队列，未修改配置。"
            snapshots[$interface]=$output
            root=$(awk '$1=="qdisc" {for(i=1;i<=NF;i++) if($i=="root") print $2}' <<< "$output")
            if grep -Eq 'qdisc cake .*bandwidth [0-9]' <<< "$output" && [[ $QDISC != cake ]]; then
                die "$interface 已配置 CAKE 限速；请先处理该限速规则，再切换算法。"
            fi
            case $root in
                cake|fq|fq_codel|pfifo_fast)
                    if [[ $root != "$QDISC" || $QDISC == fq ]]; then change_interfaces+=("$interface"); change_parents+=(root); fi ;;
                mq)
                    leaves=0
                    while read -r kind parent; do
                        [[ $kind =~ ^(cake|fq|fq_codel|pfifo_fast)$ && $parent =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ ]] || die "$interface 含有复杂子队列，未修改配置。"
                        leaves=$((leaves+1))
                        if [[ $kind != "$QDISC" ]]; then change_interfaces+=("$interface"); change_parents+=("$parent"); fi
                    done < <(awk '$1=="qdisc" && $2!="mq" && $2!="ingress" && $2!="clsact" {
                        parent=""; for(i=1;i<NF;i++) if($i=="parent") parent=$(i+1);
                        print $2, parent
                    }' <<< "$output")
                    ((leaves)) || die "$interface 的多队列信息不完整，未修改配置。" ;;
                *) die "$interface 当前为 ${root:-未知} 队列，不自动替换该队列结构。" ;;
            esac
            printf '  %s：%s → %s\n' "$interface" "$root" "$QDISC"
        done
    fi
    if ((DRY)); then log '仅预览，未修改队列或配置。'; return 0; fi
    init_state
    # Check for external edits/symlinks before touching the running queues.
    track_file "$SYSCTL"
    track_file "/etc/modules-load.d/$TAG"
    if ((TEST == 0)); then
        modprobe "sch_$QDISC" || die "当前内核无法加载 sch_$QDISC，未切换队列。"
        save_runtime net.core.default_qdisc
        install -d -m 700 "$STATE/queue-snapshots"
        for interface in "${interfaces[@]}"; do
            if [[ ! -f $STATE/queue-snapshots/$interface.before ]]; then
                printf '%s\n' "${snapshots[$interface]}" > "$STATE/queue-snapshots/$interface.before"
            fi
        done
        for ((index=0; index<${#change_interfaces[@]}; index++)); do
            interface=${change_interfaces[index]}; parent=${change_parents[index]}
            local -a attach=(root)
            [[ $parent == root ]] || attach=(parent "$parent")
            # Explicit queue fq establishes a known, replayable baseline for
            # optional shaping. Never mark arbitrary pre-existing fq as owned.
            if [[ $parent == root && $QDISC == fq ]]; then
                # replace with the same handle/type can keep old custom
                # options. A different temporary handle forces recreation.
                if ! grep -Eq '^qdisc fq 7a01: root' <<< "${snapshots[$interface]}"; then
                    tc qdisc replace dev "$interface" root handle 7a01: fq || die 'Could not create a fresh fq baseline'
                fi
                attach+=(handle 7a00:)
            fi
            if ! tc qdisc replace dev "$interface" "${attach[@]}" "$QDISC"; then
                warn '切换未全部完成；已更改的队列保留当前状态，开机配置尚未更新。'
                printf '当前队列：%s\n' "$(menu_qdisc_status)"
                die '请查看上方错误后重新选择队列算法。'
            fi
        done
        if ! check_qdiscs "$QDISC"; then die '实际队列与目标不一致，未保存开机配置。'; fi
        if ! sysctl -w "net.core.default_qdisc=$QDISC"; then
            die '网卡队列已切换，但系统默认队列更新失败，未保存开机配置。'
        fi
        current=$(sysctl -n net.core.default_qdisc)
        [[ $current == "$QDISC" ]] || die '默认队列校验失败，未保存开机配置。'
    fi
    persist_queue_choice
    if ((TEST == 0)); then
        for interface in "${interfaces[@]}"; do
            if [[ $QDISC == fq ]]; then shape_mark_fq "$interface"
            else shape_forget_queue "$interface"; fi
        done
    fi
    if ((TEST)); then log '测试配置已保存；未修改运行中的网卡队列。'
    else
        log "已切换为 ${QDISC^^}，并保存开机配置。"
        menu_status_row 网卡队列 qdiscs "$(menu_qdisc_status)"
    fi
}

check_qdiscs() {
    local expected=${1:-$(configured_qdisc)} interface output bad=0
    local -a interfaces=()
    if ! command -v ip >/dev/null || ! command -v tc >/dev/null; then
        warn 'ip/tc unavailable; actual queues are unverified'; return 2
    fi
    mapfile -t interfaces < <({ ip -o -4 route show default; ip -o -6 route show default; } |
        awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
    if ((${#interfaces[@]} == 0)); then warn 'No default-route interface; queues are unverified'; return 2; fi
    for interface in "${interfaces[@]}"; do
        log "Actual egress qdisc: $interface"
        if shape_is_active_interface "$interface"; then
            shape_check_status || bad=1
            continue
        fi
        if ! output=$(tc qdisc show dev "$interface"); then bad=1; continue; fi
        printf '%s\n' "$output"
        # mq is a valid root when every transmit leaf matches. ingress/clsact
        # are unrelated hooks; don't count them as egress queue disciplines.
        if ! awk -v expected="$expected" '
            $1=="qdisc" && $2!="ingress" && $2!="clsact" {
                if ($2==expected) matched++;
                else if ($2!="mq") bad=1;
            }
            END {exit !(matched>0 && !bad)}' <<< "$output"; then
            warn "$interface 未全部使用 $expected；请检查网卡配置或使用菜单 8 切换队列。"
            bad=1
        fi
    done
    ((bad == 0)) || return 2
}

check_status() {
    local bad=0 line key desired actual kernel_target image_pkg
    log "OS: Debian $VERSION_ID; running kernel: $(uname -r)"
    if [[ -f $STATE/kernel-release ]]; then
        kernel_target=$(cat "$STATE/kernel-release")
        if [[ -f $STATE/kernel-package ]]; then
            image_pkg=$(dpkg-query -W -f='${Depends}\n' "$(cat "$STATE/kernel-package")" 2>/dev/null | tr ',' '\n' | awk '/linux-image-/ {print $1; exit}') || image_pkg=
            [[ $image_pkg != linux-image-*xanmod* ]] || kernel_target=${image_pkg#linux-image-}
        fi
        log "Installed target: $kernel_target"
        if [[ $(uname -r) != "$kernel_target" ]]; then warn 'The selected XanMod version is not running; reboot/boot verification still required'; bad=1; fi
    fi
    [[ -f $SYSCTL ]] || { warn 'No tuning configuration'; return 2; }
    grep '^# Buffer plan:' "$SYSCTL" || true
    while IFS= read -r line; do
        [[ $line == *=* && $line != \#* ]] || continue
        key=${line%%=*}; key=${key// /}; key=${key#-}
        desired=$(xargs <<< "${line#*=}")
        actual=$(sysctl -n "$key" 2>/dev/null | xargs) || actual=unavailable
        printf '%s: actual=%s desired=%s\n' "$key" "$actual" "$desired"
        [[ $actual == "$desired" ]] || bad=1
    done < "$SYSCTL"
    if [[ $(cat /proc/1/comm) == systemd && -f /etc/systemd/system.conf.d/$TAG ]]; then
        systemctl show -p DefaultLimitNOFILE -p DefaultLimitNOFILESoft
        local target
        target=$(awk -F= '/^DefaultLimitNOFILE=/ {split($2,a,":"); print a[1]}' /etc/systemd/system.conf.d/$TAG)
        for key in DefaultLimitNOFILE DefaultLimitNOFILESoft; do
            actual=$(systemctl show -p "$key" --value)
            [[ $actual == "$target" ]] || bad=1
        done
    elif [[ $(cat /proc/1/comm) != systemd ]]; then
        warn 'No systemd PID 1; effective system defaults and boot are unverified'
        bad=1
    fi
    check_qdiscs || bad=1
    shape_check_status || bad=1
    log "Current shell limit: soft=$(ulimit -Sn), hard=$(ulimit -Hn). Re-login for PAM limits."
    if ((bad)); then warn 'CHECK: differences/pending/unverified items exist (exit 2)'; return 2; fi
    log 'CHECK: inspected runtime values and default-route queues match. Verify new login sessions separately.'
}

rollback() {
    [[ -s $STATE/manifest ]] || die 'No tracked configuration to restore'
    local path key value archived failed=0
    while IFS= read -r path; do
        if [[ -f $STATE/expected-absent$path && ( -e $path || -L $path ) ]]; then
            die "Rollback would delete a later file: $path. Back it up/reconcile first"
        fi
        if [[ -f $STATE/expected$path ]]; then
            if [[ ! -f $path || -L $path ]] || ! cmp -s "$path" "$STATE/expected$path"; then die "Rollback would overwrite a later edit: $path. Back it up/reconcile first"; fi
        fi
    done < "$STATE/manifest"
    ((DRY == 0)) || { log 'Would restore the following paths:'; cat "$STATE/manifest"; return 0; }
    if ((TEST == 0)); then shape_rollback; fi
    while IFS= read -r path; do
        if [[ -f $STATE/original$path ]]; then cp -a -- "$STATE/original$path" "$path"; else rm -f -- "$path"; fi
        # Keep rollback retryable if a later runtime/service/GRUB step fails.
        if [[ -f $path ]]; then
            cp -- "$path" "$STATE/expected$path"
            rm -f -- "$STATE/expected-absent$path"
        else
            rm -f -- "$STATE/expected$path"
            mkdir -p "$STATE/expected-absent$(dirname "$path")"
            touch "$STATE/expected-absent$path"
        fi
    done < "$STATE/manifest"
    if ((TEST == 0)); then
        while IFS='=' read -r key value; do
            [[ -n $key ]] || continue
            if ! sysctl -w "$key=$value"; then
                warn "Could not restore live sysctl: $key; reboot and verify"
                failed=1
            fi
        done < "$STATE/runtime.before"
        systemctl daemon-reload || failed=1
        systemctl daemon-reexec || failed=1
        if grep -qF '/etc/default/grub.d/90-vps-tune.cfg' "$STATE/manifest"; then update-grub || failed=1; fi
    fi
    if ((failed)); then
        die 'Persistent files restored, but live rollback is incomplete; backup retained for retry'
    fi
    archived="${STATE}.rolled-back.$(date +%Y%m%d%H%M%S).$$"
    mv -- "$STATE" "$archived"
    log "Configuration restored; audit backup: $archived"
    warn 'Packages/kernels remain installed; running kernel/process limits remain until reboot/restart. To revert kernel, choose the Debian kernel in GRUB first'
    if [[ -d $archived/queue-snapshots ]]; then warn '开机队列配置已回滚；运行中的网卡队列需手动重启后重新建立。'; fi
}

menu_read() {
    local prompt=$1 default=${2:-}
    ui_text accent "$prompt" >&2
    if ! IFS= read -r REPLY; then printf '\n' >&2; return 1; fi
    [[ -n $REPLY ]] || REPLY=$default
}

menu_number() {
    local prompt=$1 maximum=$2
    while true; do
        menu_read "$prompt" || return 1
        valid_positive "$REPLY" "$maximum" && return 0
        printf '请输入大于 0 且不超过 %s 的数字。\n' "$maximum" >&2
    done
}

menu_terms() {
    printf '\n测速会消耗公网流量，并联系 Ookla 测速服务。\n'
    printf '仅同意其许可和隐私条款后继续：https://www.speedtest.net/about/terms\n'
    printf 'https://www.speedtest.net/about/privacy\n'
    menu_read '输入 y 接受并测速，回车返回菜单 [y/N]：' n || return 1
    [[ $REPLY == y || $REPLY == Y ]]
}

menu_run() {
    # A fresh bash process preserves errexit inside the actual action. Calling
    # main() conditionally here would silently disable errexit in its functions.
    local result
    if bash "$SCRIPT_SELF" "$@"; then
        printf '\n已完成，返回主菜单。\n'
    else
        result=$?
        if ((result == 2)); then printf '\n存在待生效或未验证项目，请查看上方结果。\n'
        else printf '\n操作未完成（退出码 %s），请查看上方错误；已返回主菜单。\n' "$result"; fi
    fi
}

menu_base_args() {
    MENU_ARGS=(apply --review --nofile "$MENU_NOFILE" --cpu-level "$MENU_CPU")
    ((TEST == 0)) || MENU_ARGS+=(--container-test)
    ((MENU_DKMS == 0)) || MENU_ARGS+=(--allow-dkms)
}

menu_intro() {
    local selected
    selected=$(configured_qdisc)
    case $1 in
        1)
            print_heading '完整配置'
            printf '安装/更新 XanMod 内核，配置 BBR + %s、系统文件句柄和网络缓冲。\n' "${selected^^}"
            printf '完成后需手动重启以启用新内核。\n' ;;
        2)
            print_heading '常规调优'
            printf '保留当前内核，配置 BBR + %s、系统文件句柄和网络缓冲。\n' "${selected^^}"
            printf '按本机内存设置缓冲上限。\n' ;;
        3)
            print_heading '智能带宽调优'
            printf '保留当前内核，按带宽和参考 RTT 计算缓冲上限，并配置文件句柄及网络参数。\n'
            printf '支持手动带宽、测速和 JSON 导入；测速会消耗公网流量。\n'
            printf '计算后可保留自动建议，或手动指定缓冲上限。\n' ;;
    esac
    menu_read '输入 y 确认继续，回车返回 [y/N]：' n || return 1
    [[ $REPLY == y || $REPLY == Y ]]
}

menu_queue() {
    local selected
    print_heading '切换队列算法'
    printf '当前默认：%s\n' "$(runtime_value net.core.default_qdisc)"
    printf '即时切换并保存，使用所选算法的默认参数。\n'
    menu_item 1 CAKE
    menu_item 2 FQ
    menu_item 3 FQ_CODEL
    menu_item 0 返回 muted
    menu_read '请选择 [0]：' 0 || return 0
    case $REPLY in
        1) selected=cake ;; 2) selected=fq ;; 3) selected=fq_codel ;;
        0) return 0 ;; *) printf '无效选择，返回菜单。\n'; return 0 ;;
    esac
    local -a args=(queue --qdisc "$selected")
    ((TEST == 0)) || args+=(--container-test)
    menu_run "${args[@]}"
}

menu_shape() {
    print_heading '出口整形与测量（可选）'
    printf '仅支持本脚本用菜单 8 建立的标准单根 FQ；不接管多队列或第三方整形。\n'
    printf '整形影响整张出口网卡；扫描会临时切换队列并消耗真实流量。\n'
    printf '1. 预览扫描计划\n2. 执行扫描（只输出建议）\n3. 手动设置整形速率\n4. 关闭本脚本整形，保留基础调优\n0. 返回\n'
    local choice peer nominal rate
    menu_read '请选择 [0]：' 0 || return 0
    choice=$REPLY
    case $choice in
        1|2)
            if [[ $choice == 2 ]] && { ((TEST)) || is_container; }; then
                printf '容器测试不发起真实扫描。\n'; return 0
            fi
            menu_read '有权测试的 iperf3 对端主机/IP（端口 5201）：' || return 0
            peer=$REPLY
            [[ -n $peer ]] || return 0
            menu_read '标称出口带宽（Mbit/s）：' || return 0
            nominal=$REPLY
            if [[ $choice == 1 ]]; then
                menu_run sweep --peer "$peer" --nominal-mbps "$nominal" --dry-run
            else
                if ! bash "$SCRIPT_SELF" sweep --peer "$peer" --nominal-mbps "$nominal" --dry-run; then
                    printf '预览未通过，请先处理上述问题。\n'; return 0
                fi
                menu_read '已了解上述流量和影响，输入 y 执行 [y/N]：' n || return 0
                if [[ $REPLY == y || $REPLY == Y ]]; then
                    menu_run sweep --peer "$peer" --nominal-mbps "$nominal" --accept-traffic
                fi
            fi ;;
        3|4)
            if ((TEST)) || is_container; then printf '容器测试不修改真实队列。\n'; return 0; fi
            if [[ $choice == 4 ]]; then menu_run shape --off
            else
                menu_read '聚合出口速率（Mbit/s，采用扫描建议或手动测试值）：' || return 0
                rate=$REPLY
                [[ -n $rate ]] || return 0
                menu_run shape --rate-mbps "$rate"
            fi ;;
        0) return 0 ;;
        *) printf '无效选择。\n' ;;
    esac
}

menu_settings() {
    while true; do
        printf '\n参数设置（仅本次菜单会话）\n'
        printf '1. 文件句柄：%s\n2. 内核分支：%s\n3. CPU 等级：%s\n4. 常规缓冲档：%s MiB\n5. 允许已有 DKMS：%s\n0. 返回\n' \
            "$MENU_NOFILE" "$MENU_KERNEL" "$MENU_CPU" "$MENU_BUFFER" "$MENU_DKMS"
        menu_read '请选择：' || return 0
        case $REPLY in
            1)
                menu_read '输入文件句柄上限（65536～1048576）：' "$MENU_NOFILE" || return 0
                if [[ $REPLY =~ ^[1-9][0-9]{4,6}$ ]] && ((REPLY >= 65536 && REPLY <= 1048576)); then MENU_NOFILE=$REPLY
                else printf '文件句柄数量不合法。\n'; fi ;;
            2)
                menu_read '内核分支：lts（推荐）或 main：' lts || return 0
                if [[ $REPLY == lts || ( $REPLY == main && $VERSION_ID == 13 ) ]]; then MENU_KERNEL=$REPLY
                else printf 'Debian 12 仅支持 LTS；Debian 13 支持 lts/main。\n'; fi ;;
            3)
                menu_read 'CPU 等级：auto / v1 / v2 / v3：' auto || return 0
                if [[ $REPLY =~ ^(auto|v1|v2|v3)$ ]]; then MENU_CPU=$REPLY; else printf '无效 CPU 等级。\n'; fi ;;
            4)
                menu_read '常规缓冲上限：auto 或 4～256 MiB 整数（仍受内存预算约束）：' auto || return 0
                if [[ $REPLY == auto ]] || { [[ $REPLY =~ ^[1-9][0-9]{0,2}$ ]] && ((REPLY >= 4 && REPLY <= 256)); }; then MENU_BUFFER=$REPLY; else printf '无效缓冲上限。\n'; fi ;;
            5)
                menu_read '已自行核实 DKMS 模块兼容性？允许继续输入 y [y/N]：' n || return 0
                MENU_DKMS=0
                [[ $REPLY != y && $REPLY != Y ]] || MENU_DKMS=1 ;;
            0) return 0 ;;
            *) printf '请选择 0～5。\n' ;;
        esac
    done
}

menu_smart() {
    menu_base_args
    MENU_ARGS+=(--kernel skip --smart-bandwidth)
    printf '\n智能带宽调优（保留当前内核）\n'
    printf '自动探测大陆公开测点，或按节点区域选规划值。\n'
    printf '1. 亚太节点（参考 RTT 100 ms）\n2. 欧美节点（参考 RTT 200 ms）\n3. 高级：自定义 RTT / 原项目经验表\n4. 自动探测大陆三网 RTT（推荐）\n0. 返回\n'
    menu_read '选择 RTT 方案 [4]：' 4 || return 0
    case $REPLY in
        1) MENU_ARGS+=(--smart-profile asia-bdp) ;;
        2) MENU_ARGS+=(--smart-profile overseas-bdp) ;;
        4)
            if ((TEST)) || is_container; then printf '容器测试不发起公网 RTT 探测，请选择区域参考值或手动 RTT。\n'; return 0; fi
            MENU_ARGS+=(--smart-profile bdp --auto-rtt) ;;
        3)
            printf '1. 自定义代表性 RTT（BDP）\n2. 原项目亚太带宽表（不用 RTT）\n3. 原项目欧美带宽表（不用 RTT）\n0. 返回\n'
            menu_read '请选择 [1]：' 1 || return 0
            case $REPLY in
                1)
                    MENU_ARGS+=(--smart-profile bdp)
                    menu_number '输入多地区代表性 TCP RTT（ms）：' 5000 || return 0
                    MENU_ARGS+=(--rtt-ms "$REPLY") ;;
                2) MENU_ARGS+=(--smart-profile asia) ;;
                3) MENU_ARGS+=(--smart-profile overseas) ;;
                *) return 0 ;;
            esac ;;
        0) return 0 ;;
        *) printf '无效选择，返回菜单。\n'; return 0 ;;
    esac
    printf '\n带宽来源\n1. 临时隔离测速（下载工具，完成后清理）\n2. 手动输入带宽\n3. 导入 Ookla JSON\n0. 返回\n'
    menu_read '请选择 [2]：' 2 || return 0
    case $REPLY in
        1)
            if ((TEST)) || is_container; then printf '容器测试不发起公网测速，请选择手动带宽或 JSON。\n'; return 0; fi
            menu_terms || { printf '已取消测速。\n'; return 0; }
            MENU_ARGS+=(--speedtest --accept-speedtest-terms) ;;
        2)
            menu_number '输入出口/瓶颈带宽（Mbit/s）：' 100000 || return 0
            MENU_ARGS+=(--bandwidth-mbps "$REPLY") ;;
        3)
            menu_read '输入 JSON 文件路径：' || return 0
            [[ -f $REPLY && -r $REPLY ]] || { printf '文件不存在或不可读。\n'; return 0; }
            MENU_ARGS+=(--speedtest-json "$REPLY") ;;
        0) return 0 ;;
        *) printf '无效选择，返回菜单。\n'; return 0 ;;
    esac
    menu_run "${MENU_ARGS[@]}"
}

runtime_value() {
    local value
    if value=$(sysctl -n "$1" 2>/dev/null) && [[ -n $value ]]; then
        printf '%s' "$value"
    else
        printf '未获取'
    fi
}

menu_qdisc_status() {
    local interface output types separator=
    local -a interfaces=()
    if ! command -v ip >/dev/null || ! command -v tc >/dev/null; then
        printf '未获取'; return 0
    fi
    mapfile -t interfaces < <({ ip -o -4 route show default 2>/dev/null || true; ip -o -6 route show default 2>/dev/null || true; } |
        awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
    if ((${#interfaces[@]} == 0)); then printf '无默认路由'; return 0; fi
    for interface in "${interfaces[@]}"; do
        types=未获取
        if output=$(tc qdisc show dev "$interface" 2>/dev/null); then
            # Show real root/leaf disciplines, including mixed mq leaves.
            # ingress/clsact hooks are unrelated to the egress queue choice.
            types=$(awk '
                $1=="qdisc" && $2!="ingress" && $2!="clsact" && !seen[$2]++ {
                    printf "%s%s", sep, $2; sep="+"
                }
                END {if(sep=="") printf "未获取"}' <<< "$output")
        fi
        printf '%s%s: %s' "$separator" "$interface" "$types"
        separator=' · '
    done
}

menu_service_limits() {
    local properties key value soft='' hard=''
    # Read the running manager, not the saved drop-in or next apply's options.
    # A missing/unresponsive manager must not prevent opening the menu.
    if properties=$(timeout --kill-after=1 2 systemctl show -p DefaultLimitNOFILE -p DefaultLimitNOFILESoft 2>/dev/null); then
        while IFS='=' read -r key value; do
            case $key in
                DefaultLimitNOFILESoft) soft=$value ;;
                DefaultLimitNOFILE) hard=$value ;;
            esac
        done <<< "$properties"
    fi
    if [[ $soft =~ ^([0-9]+|infinity)$ && $hard =~ ^([0-9]+|infinity)$ ]]; then
        printf '软 %s / 硬 %s' "$soft" "$hard"
    else
        printf '未获取'
    fi
}

menu_tcp_ceiling() {
    local value
    value=$(runtime_value "$1")
    awk '
        NF==3 && $3 ~ /^[0-9]+$/ {
            mib=$3/1048576; valid=1;
            if(mib==int(mib)) printf "%d MiB", mib;
            else printf "%.2f MiB", mib;
        }
        END {if(!valid) printf "未获取"}' <<< "$value"
}

menu_status_value() {
    local kind=$1 value=$2 tone=accent
    if [[ $value == *未获取* || $value == 无默认路由 ]]; then
        tone=warning
    else
        case $kind in
            kernel) [[ $value != *xanmod* ]] || tone=good ;;
            congestion) if [[ $value == bbr* ]]; then tone=good; else tone=warning; fi ;;
            default-qdisc) if [[ $value == "$(configured_qdisc)" ]]; then tone=good; else tone=warning; fi ;;
            qdiscs)
                # Green only if every interface matches the selected kind, with no
                # different leaf discipline hidden among mq queues.
                if awk -F ' · ' -v expected="$(configured_qdisc)" '
                    {
                        for(i=1;i<=NF;i++) {
                            if(split($i,parts,": ")!=2) {bad=1; continue}
                            n=split(parts[2],types,"[+]"); matched=0;
                            for(j=1;j<=n;j++) {
                                if(types[j]==expected) matched=1;
                                else if(types[j]!="mq") bad=1;
                            }
                            if(!matched) bad=1;
                        }
                    }
                    END {exit (NR==0 || bad)}' <<< "$value"; then tone=good
                else tone=warning; fi ;;
        esac
    fi
    ui_text "$tone" "$value"
}

menu_status_row() {
    printf '%s：' "$1"
    menu_status_value "$2" "$3"
    printf '\n'
}

menu_item() {
    ui_text "${3:-accent}" "$1."
    printf ' '
    ui_text "${3:-plain}" "$2"
    printf '\n'
}

show_menu_status() {
    # Re-read on every menu display; selections and saved files are not proof
    # that the running kernel, manager or current process uses those values.
    menu_status_row 当前内核 kernel "$(uname -r)"
    printf '拥塞控制：'; menu_status_value congestion "$(runtime_value net.ipv4.tcp_congestion_control)"
    printf ' · 默认队列：'; menu_status_value default-qdisc "$(runtime_value net.core.default_qdisc)"; printf '\n'
    menu_status_row 网卡队列 qdiscs "$(menu_qdisc_status)"
    menu_status_row 进程句柄 value "软 $(ulimit -Sn) / 硬 $(ulimit -Hn)"
    menu_status_row 服务默认句柄 value "$(menu_service_limits)"
    menu_status_row 'TCP 缓冲上限' value "收 $(menu_tcp_ceiling net.ipv4.tcp_rmem) / 发 $(menu_tcp_ceiling net.ipv4.tcp_wmem)"
    printf '\n'
}

interactive_menu() {
    local SCRIPT_SELF MENU_NOFILE=$NOFILE MENU_KERNEL=$KERNEL
    local MENU_CPU=$CPU MENU_BUFFER=$BUFFER MENU_DKMS=$ALLOW_DKMS
    local -a MENU_ARGS=()
    SCRIPT_SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f $SCRIPT_SELF ]] || die '请先将脚本保存为本地文件，再打开菜单。'
    while true; do
        printf '\n'; ui_text heading "====== Debian $VERSION_ID / VPS 系统优化 ======"; printf '\n'
        show_menu_status
        ((TEST == 0)) || printf '【Docker 测试模式】不改宿主参数、不重启、不发起公网测速。\n'
        menu_item 1 完整配置
        menu_item 2 常规调优
        menu_item 3 智能带宽调优
        menu_item 4 临时测速
        menu_item 5 检查生效状态
        menu_item 6 回滚配置 warning
        menu_item 7 参数设置
        menu_item 8 切换队列算法
        menu_item 9 出口整形与扫描
        menu_item 0 退出 muted
        menu_read '请选择 [0]：' 0 || break
        case $REPLY in
            1|2)
                local choice=$REPLY
                menu_intro "$choice" || continue
                menu_base_args
                if [[ $choice == 1 ]]; then MENU_ARGS+=(--kernel "$MENU_KERNEL"); else MENU_ARGS+=(--kernel skip); fi
                MENU_ARGS+=(--buffer-mib "$MENU_BUFFER")
                menu_run "${MENU_ARGS[@]}" ;;
            3) if menu_intro 3; then menu_smart; fi ;;
            4)
                if ((TEST)) || is_container; then printf '容器测试不发起公网测速。\n'; continue; fi
                if menu_terms; then menu_run measure --accept-speedtest-terms; else printf '已取消测速。\n'; fi ;;
            5) menu_run check ;;
            6)
                local -a restore_args=(rollback)
                ((TEST == 0)) || restore_args+=(--container-test)
                if bash "$SCRIPT_SELF" "${restore_args[@]}" --dry-run; then
                    printf '将恢复以上配置；不会删除已安装内核或自动重启。\n'
                    menu_read '输入 y 执行回滚 [y/N]：' n || break
                    if [[ $REPLY == y || $REPLY == Y ]]; then menu_run "${restore_args[@]}"; else printf '已取消回滚。\n'; fi
                else printf '无法预览回滚，请查看上方原因。\n'; fi ;;
            7) menu_settings ;;
            8) menu_queue ;;
            9) menu_shape ;;
            0) break ;;
            *) printf '请选择 0～9。\n' ;;
        esac
    done
    printf '已退出菜单。\n'
}

# BEGIN OPTIONAL SHAPING
#!/usr/bin/env bash
# Optional shaping and bounded, single-stream experiments. Integration globals:
# SHAPE_RATE= SHAPE_OFF=0 SWEEP_PEER= SWEEP_NOMINAL= ACCEPT_TRAFFIC=0
# queue fq explicitly creates root handle 7a00: fq before shape_mark_fq.

validate_shape_args() {
    if [[ $ACTION != shape && $ACTION != sweep ]]; then
        if [[ -n $SHAPE_RATE || -n $SWEEP_PEER || -n $SWEEP_NOMINAL ]] || ((SHAPE_OFF != 0 || ACCEPT_TRAFFIC != 0)); then die 'Shaping options require shape or sweep'; fi
        return 0
    fi
    KERNEL=skip
    ((TEST == 0)) || die 'shape/sweep are disabled in container-test'
    if [[ $ACTION == shape ]]; then
        if [[ -n $SWEEP_PEER || -n $SWEEP_NOMINAL ]] || ((ACCEPT_TRAFFIC != 0)); then die 'Peer/traffic options require sweep'; fi
        if ((SHAPE_OFF)); then [[ -z $SHAPE_RATE ]] || die 'Choose --off OR --rate-mbps'
        else
            if [[ ! $SHAPE_RATE =~ ^[1-9][0-9]{0,5}$ ]] || ((SHAPE_RATE > 100000)); then die '--rate-mbps must be an integer, 1..100000'; fi
        fi
    else
        if [[ -n $SHAPE_RATE ]] || ((SHAPE_OFF != 0)); then die 'sweep does not accept shape options'; fi
        [[ $SWEEP_PEER =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$ ]] || die '--peer requires your own/authorized iperf3 host or IP (port 5201)'
        if [[ ! $SWEEP_NOMINAL =~ ^[1-9][0-9]{0,4}$ ]] || ((SWEEP_NOMINAL > 10000)); then die '--nominal-mbps must be an integer, 1..10000'; fi
        ((ACCEPT_TRAFFIC || DRY)) || die 'sweep sends real traffic; explicitly pass --accept-traffic'
    fi
}

# tc's refcnt changes as links are referenced; it is not a tunable. Everything
# else, including handles, fq options and class rates, remains in the signature.
shape_signature() {
    local iface=$1 q c
    q=$(tc qdisc show dev "$iface") || return 1
    c=$(tc class show dev "$iface") || return 1
    printf '%s\n%s\n' "$q" "$c" | sed -E 's/ refcnt [0-9]+//g; s/ direct_packets_stat [0-9]+//g; /^[[:space:]]*$/d'
}

shape_filter_guard() {
    local iface=$1 parent filters
    # Only the flat fq or our two-qdisc tree is accepted. ingress/clsact and
    # additional leaves change the signature and are rejected as well.
    for parent in root 7a10: 7a10:1; do
        if [[ $parent == root ]]; then filters=$(tc filter show dev "$iface" root) || return 1
        else filters=$(tc filter show dev "$iface" parent "$parent") || return 1; fi
        [[ -z $filters ]] || { warn "Filters exist on $iface/$parent; refusing to replace queues"; return 1; }
    done
}

shape_mark_fq() {
    local iface=$1 signature
    [[ $iface =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $iface != . && $iface != .. ]] || return 1
    signature=$(shape_signature "$iface") || return 1
    # Called only after an explicit queue fq has CREATED this standard queue.
    [[ $signature == 'qdisc fq 7a00: root '* && $signature != *$'\n'* ]] || return 0
    shape_filter_guard "$iface" || return 1
    install -d -m 700 "$STATE/shaping"
    printf '%s\n' "$signature" > "$STATE/shaping/fq.$iface"
}

shape_forget_queue() {
    local iface=$1
    [[ $iface =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $iface != . && $iface != .. ]] || return 1
    rm -f -- "$STATE/shaping/fq.$iface"
}

shape_read_active() {
    SHAPE_ACTIVE_IFACE=; SHAPE_ACTIVE_RATE=
    [[ -f $STATE/shaping/active ]] || return 0
    read -r SHAPE_ACTIVE_IFACE SHAPE_ACTIVE_RATE < "$STATE/shaping/active" || return 1
    [[ $SHAPE_ACTIVE_IFACE =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $SHAPE_ACTIVE_IFACE != . && $SHAPE_ACTIVE_IFACE != .. && $SHAPE_ACTIVE_RATE =~ ^[1-9][0-9]{0,5}$ ]] && ((SHAPE_ACTIVE_RATE <= 100000))
}

shape_is_active_interface() {
    shape_read_active || return 1
    [[ -n $SHAPE_ACTIVE_IFACE && $SHAPE_ACTIVE_IFACE == "$1" ]]
}

shape_require_owned() {
    local iface=$1 actual expected fq_expected boot_expected
    [[ -f $STATE/shaping/fq.$iface ]] || die "No managed fq snapshot for $iface; first run queue --qdisc fq explicitly (single-root interfaces only)"
    shape_filter_guard "$iface" || die 'Queue filters are not safely restorable'
    actual=$(shape_signature "$iface") || die 'Cannot read current queues'
    fq_expected=$(cat "$STATE/shaping/fq.$iface")
    boot_expected=${fq_expected/qdisc fq 7a00: root/qdisc fq 0: root}
    shape_read_active || die 'Invalid shaping state'
    if [[ -n $SHAPE_ACTIVE_IFACE ]]; then
        [[ $iface == "$SHAPE_ACTIVE_IFACE" ]] || die 'A different interface is already shaped; use shape --off first'
        # Boot/service failures can leave the known fq intact while a persisted
        # cap remains configured. Permit retry/off without guessing custom state.
        if [[ $actual == "$fq_expected" ]]; then return 0; fi
        if [[ $actual == "$boot_expected" ]]; then
            [[ $(sysctl -n net.core.default_qdisc) == fq ]] || die 'Cannot safely restore kernel-created fq after changing its default'
            return 0
        fi
        [[ -f $STATE/shaping/active.signature ]] || die 'Missing active queue signature'
        expected=$(cat "$STATE/shaping/active.signature")
    else expected=$fq_expected; fi
    [[ $actual == "$expected" ]] || die 'Queue parameters/handles changed externally; refusing to replace or guess a restoration'
}

shape_put_fq() {
    local iface=$1 actual expected=''
    actual=$(shape_signature "$iface") || return 1
    [[ ! -f $STATE/shaping/fq.$iface ]] || expected=$(cat "$STATE/shaping/fq.$iface")
    if [[ $actual == 'qdisc fq 7a00: root '* ]]; then
        # Some kernels reject in-place fq changes; others retain omitted
        # parameters. Never treat a same-handle replace as a fresh fq.
        [[ -n $expected && $actual == "$expected" ]] || return 1
        return 0
    fi
    tc qdisc replace dev "$iface" root handle 7a00: fq || return 1
    [[ -z $expected || $(shape_signature "$iface") == "$expected" ]]
}

shape_put_rate() {
    local iface=$1 rate=$2 burst
    burst=$((rate * 500)); ((burst >= 32768)) || burst=32768
    # Recreate the tree, including its fq leaf, with identical defaults for
    # every test and final deployment. Omitted options must not leak across runs.
    shape_put_fq "$iface" || return 1
    tc qdisc replace dev "$iface" root handle 7a10: htb default 1 || return 1
    tc class replace dev "$iface" parent 7a10: classid 7a10:1 htb \
        rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$burst" quantum 1514 || return 1
    tc qdisc replace dev "$iface" parent 7a10:1 handle 7a11: fq maxrate "${rate}mbit" || return 1
}

shape_verify_rate() {
    local iface=$1 rate=$2 q classes
    q=$(tc qdisc show dev "$iface") || return 1
    classes=$(tc class show dev "$iface") || return 1
    # tc selects Kbit/Mbit/Gbit dynamically; compare normalized numbers.
    awk '$1=="qdisc" {n++; if($2=="htb" && $3=="7a10:" && $4=="root") r++; if($2=="fq" && $3=="7a11:" && $4=="parent" && $5=="7a10:1") f++} END {exit !(n==2 && r==1 && f==1)}' <<< "$q" || return 1
    awk -v wanted="$rate" '
        function mbps(x, n) {n=x+0; if(x~/Gbit$/) return n*1000; if(x~/Mbit$/) return n; if(x~/Kbit$/) return n/1000; if(x~/bit$/) return n/1000000; return -1}
        $1=="class" {n++; if($2!="htb" || $3!="7a10:1") bad=1; for(i=1;i<NF;i++) {if($i=="rate") rate=mbps($(i+1)); if($i=="ceil") ceil=mbps($(i+1))}}
        END {exit !(n==1 && !bad && rate>=wanted*.99 && rate<=wanted*1.01 && ceil>=wanted*.99 && ceil<=wanted*1.01)}' <<< "$classes"
}

shape_restore_original() {
    [[ $(shape_signature "$SHAPE_IFACE") != "$SHAPE_BEFORE_SIGNATURE" ]] || return 0
    if [[ -n $SHAPE_BEFORE_RATE ]]; then shape_put_rate "$SHAPE_IFACE" "$SHAPE_BEFORE_RATE" || return 1
    elif [[ $SHAPE_BEFORE_SIGNATURE == 'qdisc fq 0: root '* ]]; then
        [[ $(sysctl -n net.core.default_qdisc) == fq ]] || return 1
        tc qdisc del dev "$SHAPE_IFACE" root || return 1
    else shape_put_fq "$SHAPE_IFACE" || return 1; fi
    [[ $(shape_signature "$SHAPE_IFACE") == "$SHAPE_BEFORE_SIGNATURE" ]]
}

shape_owned_files_guard() {
    local path
    for path in /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service; do
        [[ ! -L $path ]] || die "Refusing symlink: $path"
        if [[ -e $path ]]; then
            if [[ ! -f $STATE/expected$path ]] || ! cmp -s "$path" "$STATE/expected$path"; then die "Existing/unmanaged shaping file: $path"; fi
        fi
    done
    local link=/etc/systemd/system/multi-user.target.wants/vps-tune-shape.service
    if [[ -e $link || -L $link ]]; then
        [[ -L $link && $(readlink "$link") == /etc/systemd/system/vps-tune-shape.service ]] || die 'Unexpected shaping service enable link'
    fi
}

# Used by the generated systemd helper. A kernel-created fq root after boot has
# handle 0:. Accept it only when ALL remaining parameters match the owned fq
# template; mq, custom/default-changed queues, classes and filters are rejected.
shape_service_restore() {
    local rc=$1
    trap - EXIT ERR INT TERM HUP
    if ((SHAPE_SERVICE_PENDING)); then
        if [[ $SHAPE_SERVICE_BEFORE == 'qdisc fq 0: root '* ]]; then
            tc qdisc del dev "$SHAPE_IFACE" root || rc=1
        elif [[ $SHAPE_SERVICE_BEFORE == 'qdisc fq 7a00: root '* ]]; then
            shape_put_fq "$SHAPE_IFACE" || rc=1
        else shape_put_rate "$SHAPE_IFACE" "$SHAPE_RATE" || rc=1; fi
        [[ $(shape_signature "$SHAPE_IFACE") == "$SHAPE_SERVICE_BEFORE" ]] || { warn 'Service could not restore its original queue; inspect tc'; rc=1; }
    fi
    exit "$rc"
}

shape_service_start() {
    local actual expected boot_expected signature temporary
    shape_filter_guard "$SHAPE_IFACE" || die 'Unsafe filters at shaping startup'
    actual=$(shape_signature "$SHAPE_IFACE") || die 'Cannot inspect startup queues'
    expected=$(cat "$STATE/shaping/fq.$SHAPE_IFACE") || die 'Missing fq ownership state'
    boot_expected=${expected/qdisc fq 7a00: root/qdisc fq 0: root}
    if [[ $actual != "$expected" && $actual != "$boot_expected" ]]; then
        [[ -f $STATE/shaping/active.signature && $actual == "$(cat "$STATE/shaping/active.signature")" ]] || die 'Startup queue differs from owned fq/HTB; left untouched'
    fi
    # Deleting a newly installed tree can restore the kernel's handle-0 fq only
    # while the default is still fq. Refuse before mutation if this changed.
    if [[ $actual == "$boot_expected" ]]; then
        [[ $(sysctl -n net.core.default_qdisc) == fq ]] || die 'Kernel fq default changed; cannot safely restore boot queue'
    fi
    SHAPE_SERVICE_BEFORE=$actual; SHAPE_SERVICE_PENDING=1
    trap 'shape_service_restore "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    shape_put_rate "$SHAPE_IFACE" "$SHAPE_RATE" || die 'Shaping service could not install HTB/fq'
    shape_verify_rate "$SHAPE_IFACE" "$SHAPE_RATE" || die 'Shaping service could not verify its rate'
    signature=$(shape_signature "$SHAPE_IFACE") || die 'Cannot read applied shaping signature'
    temporary=$(mktemp "$STATE/shaping/.active-signature.XXXXXX") || die 'Cannot stage shaping signature'
    printf '%s\n' "$signature" > "$temporary" || { rm -f -- "$temporary"; die 'Cannot write shaping signature'; }
    mv -f -- "$temporary" "$STATE/shaping/active.signature" || die 'Cannot commit shaping signature'
    SHAPE_SERVICE_PENDING=0
}

shape_write_service() {
    local name
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexport LC_ALL=C\nexport PATH=/usr/sbin:/usr/bin:/sbin:/bin\n'
        printf 'STATE=%q\nSHAPE_IFACE=%q\nSHAPE_RATE=%q\n' "$STATE" "$SHAPE_IFACE" "$SHAPE_RATE"
        printf 'warn() { printf "%%s\\n" "$*" >&2; }\ndie() { warn "$*"; exit 1; }\n'
        for name in shape_signature shape_filter_guard shape_put_fq shape_put_rate shape_verify_rate shape_service_restore shape_service_start; do declare -f "$name"; done
        printf 'exec 9>/run/lock/vps-tune.lock\nflock -w 30 9 || die "vps-tune is busy"\nshape_service_start\n'
    } | write_file /usr/local/sbin/vps-tune-shape
    # Execute through bash; write_file intentionally leaves a regular 0644 file.
    write_file /etc/systemd/system/vps-tune-shape.service <<'EOF'
[Unit]
Description=VPS tune owned HTB and fq egress shaping
Wants=network-online.target
After=network-online.target
ConditionPathExists=/var/lib/vps-tune/shaping/active

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/vps-tune-shape
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

shape_check_status() {
    shape_read_active || { warn 'Invalid shaping state'; return 2; }
    [[ -n $SHAPE_ACTIVE_IFACE ]] || return 0
    local actual
    actual=$(shape_signature "$SHAPE_ACTIVE_IFACE") || return 2
    if [[ ! -f $STATE/shaping/active.signature || $actual != "$(cat "$STATE/shaping/active.signature")" ]] || ! shape_filter_guard "$SHAPE_ACTIVE_IFACE" || ! shape_verify_rate "$SHAPE_ACTIVE_IFACE" "$SHAPE_ACTIVE_RATE"; then
        warn 'Managed shaping does not match its saved rate/queue parameters'; return 2
    fi
    if ! systemctl is-enabled --quiet vps-tune-shape.service; then warn 'Shaping works now but its boot service is disabled'; return 2; fi
    log "Managed HTB ${SHAPE_ACTIVE_RATE} Mbit/s + fq on $SHAPE_ACTIVE_IFACE"
}

# Back up only this feature's two regular files and active state. Original
# file snapshots remain in the normal manifest for the global rollback.
shape_backup_persistence() {
    local path backup
    backup=$(mktemp -d "$STATE/shaping/.transaction.XXXXXX")
    for path in /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service; do
        if [[ -f $path ]]; then mkdir -p "$backup$(dirname "$path")"; cp -a -- "$path" "$backup$path"; fi
    done
    if systemctl is-enabled --quiet vps-tune-shape.service 2>/dev/null; then SHAPE_WAS_ENABLED=1; else SHAPE_WAS_ENABLED=0; fi
    [[ ! -f $STATE/shaping/active ]] || cp -- "$STATE/shaping/active" "$backup/active"
    [[ ! -f $STATE/shaping/active.signature ]] || cp -- "$STATE/shaping/active.signature" "$backup/active.signature"
    SHAPE_PERSIST_BACKUP=$backup
}

shape_restore_persistence() {
    local path item failed=0
    for path in /usr/local/sbin/vps-tune-shape /etc/systemd/system/vps-tune-shape.service; do
        if [[ -f $SHAPE_PERSIST_BACKUP$path ]]; then
            cp -a -- "$SHAPE_PERSIST_BACKUP$path" "$path" || failed=1
            cp -- "$SHAPE_PERSIST_BACKUP$path" "$STATE/expected$path" || failed=1
            rm -f -- "$STATE/expected-absent$path" || failed=1
        else
            rm -f -- "$path" "$STATE/expected$path" || failed=1
            mkdir -p "$STATE/expected-absent$(dirname "$path")" || failed=1
            touch "$STATE/expected-absent$path" || failed=1
        fi
    done
    for item in active active.signature; do
        if [[ -f $SHAPE_PERSIST_BACKUP/$item ]]; then cp -- "$SHAPE_PERSIST_BACKUP/$item" "$STATE/shaping/$item" || failed=1
        else rm -f -- "$STATE/shaping/$item" || failed=1; fi
    done
    systemctl daemon-reload || failed=1
    if ((SHAPE_WAS_ENABLED)); then systemctl enable vps-tune-shape.service || failed=1
    elif [[ -f /etc/systemd/system/vps-tune-shape.service ]]; then systemctl disable vps-tune-shape.service || failed=1
    else
        # disable may return an error after restoring an originally absent unit;
        # its only owned enable link is safe to remove directly in that case.
        rm -f -- /etc/systemd/system/multi-user.target.wants/vps-tune-shape.service || failed=1
    fi
    ((failed == 0))
}

shape_transaction_finish() {
    local rc=$1 restored=1 persistence_restored=1
    trap - EXIT ERR INT TERM HUP
    # A background timeout plus wait lets Bash run signal traps immediately.
    # GNU timeout owns its process group and forwards TERM to iperf3; its
    # --kill-after=2 also bounds shutdown if the client ignores termination.
    if [[ -n ${SHAPE_IPERF_PID:-} ]]; then
        kill -TERM -- "-$SHAPE_IPERF_PID" 2>/dev/null || kill -TERM "$SHAPE_IPERF_PID" 2>/dev/null || true
        wait "$SHAPE_IPERF_PID" 2>/dev/null || true
        SHAPE_IPERF_PID=''
    fi
    if ((SHAPE_RESTORE)); then
        if shape_restore_original; then log 'Restored the pre-experiment queue, including its handle and parameters'
        else warn 'Queue restoration failed; inspect tc and the saved signature before resuming workloads'; restored=0; rc=1; fi
    fi
    if [[ -n $SHAPE_PERSIST_BACKUP ]]; then
        if ((rc != 0)); then
            shape_restore_persistence || { warn "Could not fully restore shaping persistence; recovery files retained: $SHAPE_PERSIST_BACKUP"; persistence_restored=0; rc=1; }
        fi
        if ((persistence_restored)); then rm -rf -- "$SHAPE_PERSIST_BACKUP"; fi
    fi
    ((restored)) || printf '%s\n' "$SHAPE_BEFORE_SIGNATURE" >&2
    exit "$rc"
}

# One TCP stream, sender-side retransmissions divided by estimated segment
# count from sent bytes / reported MSS. This is NOT packet-loss probability.
shape_sample() {
    local label=$1 rate=$2 file values rc
    ((SHAPE_SAMPLE_COUNT < 28)) || die 'Experiment stopped at its 28-sample budget'
    SHAPE_SAMPLE_COUNT=$((SHAPE_SAMPLE_COUNT + 1))
    file="$SHAPE_LOG_DIR/$(printf '%02d' "$SHAPE_SAMPLE_COUNT")-$label.json"
    timeout --signal=TERM --kill-after=2 22 iperf3 --client "$SWEEP_ADDRESS" --bind-dev "$SHAPE_IFACE" \
        --port 5201 --parallel 1 --time 8 --omit 2 --connect-timeout 5000 --json > "$file" 2> "$file.stderr" &
    SHAPE_IPERF_PID=$!
    if wait "$SHAPE_IPERF_PID"; then rc=0; else rc=$?; fi
    SHAPE_IPERF_PID=''
    ((rc == 0)) || die "iperf3 failed or timed out (exit $rc); retained diagnostics in $file"
    values=$(jq -er '
        if .error then error(.error) else . end |
        [.end.sum_sent.bytes, .end.sum_sent.retransmits, .end.sum_received.bits_per_second, .start.tcp_mss_default] |
        if (all(.[]; type == "number")) and .[0]>0 and .[1]>=0 and .[2]>0 and .[3]>=256 and .[3]<=65535
        then @tsv else error("Missing or invalid TCP bytes/retransmits/receiver goodput/MSS") end' "$file") || die "Unsupported/incomplete iperf3 JSON: $file"
    local bytes retrans recv mss
    IFS=$'\t' read -r bytes retrans recv mss <<< "$values"
    read -r SHAPE_SAMPLE_GOODPUT SHAPE_SAMPLE_RATIO < <(awk -v b="$bytes" -v r="$retrans" -v g="$recv" -v m="$mss" 'BEGIN {printf "%.4f %.6f\n",g/1000000,100*r*m/b}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$rate" "$SHAPE_SAMPLE_GOODPUT" "$retrans" "$SHAPE_SAMPLE_RATIO" "$bytes" "$mss" >> "$SHAPE_LOG_DIR/samples.tsv"
    log "$label: cap=${rate} Mbit/s, received=${SHAPE_SAMPLE_GOODPUT} Mbit/s, retrans=$retrans, estimated retrans/segments=${SHAPE_SAMPLE_RATIO}%"
}

shape_clean_sample() { awk -v ratio="$SHAPE_SAMPLE_RATIO" 'BEGIN {exit !(ratio <= .1)}'; }

shape_sweep_rate() {
    local rate=$1 label=$2
    shape_put_rate "$SHAPE_IFACE" "$rate" || die 'Cannot install temporary HTB/fq'
    shape_verify_rate "$SHAPE_IFACE" "$rate" || die 'Temporary shaper verification failed'
    sleep 2
    shape_sample "$label" "$rate"
    if shape_clean_sample; then
        awk -v g="$SHAPE_SAMPLE_GOODPUT" -v r="$rate" 'BEGIN {exit !(g>=r*.7)}' || die 'Rate was not exercised (received <70%); peer, path or CPU capacity makes this experiment inconclusive'
        return 0
    fi
    # A single excursion is not a stable boundary; require a second sample.
    sleep 2
    shape_sample "$label-repeat" "$rate"
    if shape_clean_sample; then die 'Retransmission spike did not repeat; no stable recommendation'; fi
    return 1
}

shape_run_sweep() {
    local base_g base_r base2_g base2_r lo hi step rate clean=0 bad=0 candidate i midpoint final1_g final1_r final2_g final2_r compare_g compare_r
    SHAPE_LOG_DIR="$STATE/sweeps/$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$SHAPE_LOG_DIR"
    printf 'label\tcap_mbps\treceived_mbps\tretransmissions\testimated_retrans_percent\tsent_bytes\tmss\n' > "$SHAPE_LOG_DIR/samples.tsv"
    log "Single-stream experiment to $SWEEP_PEER ($SWEEP_ADDRESS):5201; samples: $SHAPE_LOG_DIR"
    warn 'Estimated retransmissions/segments are not packet loss. Path congestion, CPU and peer capacity can produce the same symptoms as a policer'
    shape_put_fq "$SHAPE_IFACE" || die 'Cannot remove shaping for baseline'
    shape_sample baseline unshaped
    base_g=$SHAPE_SAMPLE_GOODPUT; base_r=$SHAPE_SAMPLE_RATIO
    if shape_clean_sample; then
        printf 'status=low-retransmissions\nNo shaping recommendation; a low sample does not establish that no policer exists.\n' > "$SHAPE_LOG_DIR/result.txt"
        log 'Baseline retransmissions are low; no scan or persistent shaping is needed from this evidence'
        return 0
    fi
    sleep 2; shape_sample baseline-repeat unshaped
    base2_g=$SHAPE_SAMPLE_GOODPUT; base2_r=$SHAPE_SAMPLE_RATIO
    if shape_clean_sample || ! awk -v a="$base_g" -v b="$base2_g" -v n="$SWEEP_NOMINAL" 'BEGIN {d=a-b;if(d<0)d=-d; exit !(d<=a*.15 && a>=n*.6 && b>=n*.6)}'; then
        log 'Baselines vary or are far below nominal; evidence is inconclusive, so no rate is recommended'
        printf 'status=inconclusive-baseline\n' > "$SHAPE_LOG_DIR/result.txt"; return 0
    fi
    read -r lo hi step < <(awk -v a="$base_g" -v b="$base2_g" -v n="$SWEEP_NOMINAL" 'BEGIN {g=(a<b?a:b);lo=int(g*.95);if(lo<1)lo=1;hi=int(g*1.8);if(hi>n*1.25)hi=int(n*1.25);if(hi>10000)hi=10000;step=int((hi-lo+9)/10);if(step<1)step=1;print lo,hi,step}')
    ((hi > lo)) || { log 'No usable scan interval'; return 0; }
    log "Scanning upward from received goodput: $lo..$hi Mbit/s, step $step, threshold 0.1% estimated retrans/segments"
    rate=$lo
    for ((i=0; i<11 && rate<=hi; i++)); do
        if shape_sweep_rate "$rate" coarse; then clean=$rate
        else bad=$rate; break; fi
        ((rate < hi)) || break
        rate=$((rate + step)); ((rate <= hi)) || rate=$hi
    done
    if ((clean == 0 || bad == 0)); then
        log 'No repeatable clean/high-retransmission boundary was bracketed; no recommendation'
        printf 'status=no-bracket\n' > "$SHAPE_LOG_DIR/result.txt"; return 0
    fi
    for ((i=0; i<4 && bad-clean>1; i++)); do
        midpoint=$(((clean+bad)/2))
        if shape_sweep_rate "$midpoint" fine; then clean=$midpoint; else bad=$midpoint; fi
    done
    candidate=$((clean * 97 / 100)); ((candidate >= 1)) || candidate=1
    shape_put_rate "$SHAPE_IFACE" "$candidate" || die 'Cannot install validation rate'
    shape_verify_rate "$SHAPE_IFACE" "$candidate" || die 'Cannot verify validation rate'
    sleep 2; shape_sample validate-1 "$candidate"
    final1_g=$SHAPE_SAMPLE_GOODPUT; final1_r=$SHAPE_SAMPLE_RATIO
    shape_put_fq "$SHAPE_IFACE" || die 'Cannot restore unshaped validation control'
    sleep 2; shape_sample baseline-final unshaped
    compare_g=$SHAPE_SAMPLE_GOODPUT; compare_r=$SHAPE_SAMPLE_RATIO
    shape_put_rate "$SHAPE_IFACE" "$candidate" || die 'Cannot install second validation rate'
    shape_verify_rate "$SHAPE_IFACE" "$candidate" || die 'Cannot verify second validation rate'
    sleep 2; shape_sample validate-2 "$candidate"
    final2_g=$SHAPE_SAMPLE_GOODPUT; final2_r=$SHAPE_SAMPLE_RATIO
    if awk -v b="$base_g" -v b2="$base2_g" -v b3="$compare_g" -v r="$base_r" -v r2="$base2_r" -v r3="$compare_r" -v g1="$final1_g" -v g2="$final2_g" -v t1="$final1_r" -v t2="$final2_r" '
        BEGIN {max=b;if(b2>max)max=b2;if(b3>max)max=b3;min=b;if(b2<min)min=b2;if(b3<min)min=b3;low=r;if(r2<low)low=r2;if(r3<low)low=r3;
        exit !(max<=min*1.15 && low>.1 && g1>=max*.98 && g2>=max*.98 && t1<=.1 && t2<=.1 && t1<=low*.2 && t2<=low*.2)}'; then
        printf 'status=validated-suggestion\nrate_mbps=%s\nNo permanent shaping was applied.\n' "$candidate" > "$SHAPE_LOG_DIR/result.txt"
        log "Both validation runs retained >=98% of the best baseline goodput and cut estimated retransmissions by >=80%. Suggested cap: $candidate Mbit/s"
        printf 'To apply explicitly: sudo bash vps-tune.sh shape --rate-mbps %s\n' "$candidate"
    else
        printf 'status=inconclusive-validation\nNo permanent shaping was applied.\n' > "$SHAPE_LOG_DIR/result.txt"
        log 'Repeated validation did not preserve throughput and reduce retransmissions consistently; no recommendation'
    fi
}

shape_rollback() (
    local SHAPE_IFACE='' SHAPE_BEFORE_RATE='' SHAPE_BEFORE_SIGNATURE='' SHAPE_RESTORE=0
    local SHAPE_PERSIST_BACKUP='' SHAPE_WAS_ENABLED=0
    trap - ERR EXIT
    trap 'shape_transaction_finish "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    shape_read_active || die 'Invalid shaping state prevents safe rollback'
    [[ -n $SHAPE_ACTIVE_IFACE ]] || return 0
    shape_owned_files_guard
    ((DRY == 0)) || { log "Would remove owned shaping and restore its fq queue on $SHAPE_ACTIVE_IFACE"; return 0; }
    shape_require_owned "$SHAPE_ACTIVE_IFACE"
    SHAPE_IFACE=$SHAPE_ACTIVE_IFACE; SHAPE_BEFORE_RATE=$SHAPE_ACTIVE_RATE
    SHAPE_BEFORE_SIGNATURE=$(shape_signature "$SHAPE_IFACE")
    [[ $SHAPE_BEFORE_SIGNATURE != 'qdisc fq '* ]] || SHAPE_BEFORE_RATE=''
    shape_backup_persistence
    SHAPE_RESTORE=1
    shape_put_fq "$SHAPE_ACTIVE_IFACE" || die 'Cannot remove owned shaping'
    [[ $(shape_signature "$SHAPE_ACTIVE_IFACE") == "$(cat "$STATE/shaping/fq.$SHAPE_ACTIVE_IFACE")" ]] || die 'fq restore did not match the saved parameters'
    systemctl disable --now vps-tune-shape.service
    rm -f -- "$STATE/shaping/active" "$STATE/shaping/active.signature"
    SHAPE_RESTORE=0
)

run_shape_action() (
    # A subshell confines all temporary experiment traps and state.
    local required iface ipline address
    local SHAPE_IFACE='' SHAPE_BEFORE_RATE='' SHAPE_BEFORE_SIGNATURE='' SHAPE_RESTORE=0
    local SHAPE_PERSIST_BACKUP='' SHAPE_WAS_ENABLED=0 SHAPE_SAMPLE_COUNT=0 SHAPE_LOG_DIR='' SWEEP_ADDRESS='' SHAPE_IPERF_PID=''
    local SHAPE_ACTIVE_IFACE='' SHAPE_ACTIVE_RATE='' SHAPE_SAMPLE_GOODPUT='' SHAPE_SAMPLE_RATIO=''
    local -a interfaces=()
    trap - ERR EXIT
    trap 'shape_transaction_finish "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    ((TEST == 0)) || die 'Shaping experiments are disabled in containers'
    for required in ip tc awk sed; do command -v "$required" >/dev/null || die "Missing $required; install prerequisites first"; done
    shape_read_active || die 'Invalid active shaping state'
    if [[ -n $SHAPE_ACTIVE_IFACE ]]; then SHAPE_IFACE=$SHAPE_ACTIVE_IFACE
    else
        mapfile -t interfaces < <({ ip -o -4 route show default; ip -o -6 route show default; } | awk '{for(i=1;i<NF;i++)if($i=="dev")print $(i+1)}' | sort -u)
        ((${#interfaces[@]} == 1)) || die 'shape/sweep require exactly one default-route interface'
        SHAPE_IFACE=${interfaces[0]}
    fi
    [[ $SHAPE_IFACE =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $SHAPE_IFACE != . && $SHAPE_IFACE != .. ]] || die 'Invalid interface name'
    if [[ $ACTION == shape && $SHAPE_OFF == 1 && -z $SHAPE_ACTIVE_IFACE ]]; then log 'No owned shaping is active'; return 0; fi
    shape_require_owned "$SHAPE_IFACE"
    if [[ $ACTION == sweep ]]; then
        log "Traffic budget: at most 28 samples, each 8 measured + 2 warmup seconds, timeout 22 seconds; nominal $SWEEP_NOMINAL Mbit/s"
        log "Nominal-rate planning estimate (28 tests): $(awk -v n="$SWEEP_NOMINAL" 'BEGIN{printf "%.2f",n*28*10/8000}') GB sent; unshaped tests can exceed nominal, so this is NOT a hard byte cap"
        ((SWEEP_NOMINAL <= 2500)) || warn 'Above 2500 Mbit/s: high traffic and HTB CPU cost can invalidate the experiment'
    fi
    if ((DRY)); then log "DRY RUN: would run $ACTION on $SHAPE_IFACE; no iperf3, configuration, queue or service changes"; return 0; fi
    KERNEL=skip; preflight
    exec 9>/run/lock/vps-tune.lock
    flock -n 9 || die 'Another vps-tune is running'
    shape_require_owned "$SHAPE_IFACE"
    shape_owned_files_guard
    init_state
    SHAPE_BEFORE_SIGNATURE=$(shape_signature "$SHAPE_IFACE")
    SHAPE_BEFORE_RATE=$SHAPE_ACTIVE_RATE
    [[ $SHAPE_BEFORE_SIGNATURE != 'qdisc fq '* ]] || SHAPE_BEFORE_RATE=''
    if [[ $ACTION == sweep ]]; then
        for required in iperf3 jq timeout getent; do command -v "$required" >/dev/null || die "sweep requires preinstalled $required; no packages are installed automatically"; done
        # Resolve only the explicitly supplied peer; never select public peers.
        address=$(getent ahosts "$SWEEP_PEER" | awk 'NR==1 {print $1}') || die 'Cannot resolve the supplied peer'
        [[ -n $address ]] || die 'Cannot resolve the supplied peer'
        ipline=$(ip route get "$address") || die 'Cannot route to supplied peer'
        iface=$(awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' <<< "$ipline")
        [[ $iface == "$SHAPE_IFACE" ]] || die 'Peer route differs from the managed interface; no traffic sent'
        SWEEP_ADDRESS=$address
        SHAPE_RESTORE=1
        shape_run_sweep
        return 0
    fi
    shape_backup_persistence
    SHAPE_RESTORE=1
    if ((SHAPE_OFF)); then
        shape_put_fq "$SHAPE_IFACE" || die 'Cannot remove shaping'
        [[ $(shape_signature "$SHAPE_IFACE") == "$(cat "$STATE/shaping/fq.$SHAPE_IFACE")" ]] || die 'Restored fq differs from its original parameters'
        systemctl disable --now vps-tune-shape.service
        rm -f -- "$STATE/shaping/active" "$STATE/shaping/active.signature"
        SHAPE_RESTORE=0
        log "Removed shaping on $SHAPE_IFACE; its previous owned fq queue is restored"
        return 0
    fi
    shape_put_rate "$SHAPE_IFACE" "$SHAPE_RATE" || die 'Cannot apply HTB/fq'
    shape_verify_rate "$SHAPE_IFACE" "$SHAPE_RATE" || die 'HTB rate verification failed'
    shape_write_service
    printf '%s %s\n' "$SHAPE_IFACE" "$SHAPE_RATE" > "$STATE/shaping/active"
    shape_signature "$SHAPE_IFACE" > "$STATE/shaping/active.signature"
    systemctl daemon-reload
    systemctl enable vps-tune-shape.service
    systemctl is-enabled --quiet vps-tune-shape.service || die 'Shaping service could not be enabled'
    SHAPE_RESTORE=0
    log "Applied aggregate HTB ${SHAPE_RATE} Mbit/s + fq to $SHAPE_IFACE; boot service enabled"
)

# END OPTIONAL SHAPING

main() {
    if (($# == 0)); then
        [[ -t 0 ]] || die '交互菜单需要终端；请运行 sudo bash vps-tune.sh。自动化请显式使用 apply/check/rollback。'
        set -- menu
    fi
    parse_args "$@"
    check_os
    if ((QDISC_EXPLICIT == 0)); then QDISC=$(configured_qdisc); fi
    if [[ $ACTION == apply && -f $STATE/shaping/active && $QDISC != fq ]]; then
        die 'Active shaping needs the fq default; run shape --off before changing the base qdisc'
    fi
    if [[ $ACTION == check ]]; then
        # A pending verification (2) is a normal check result, not an ERR trap.
        if check_status; then exit 0; else exit "$?"; fi
    fi
    ((EUID == 0)) || die 'Run as root'
    if [[ $ACTION == menu ]]; then interactive_menu; return; fi
    if [[ $ACTION == shape || $ACTION == sweep ]]; then
        run_shape_action
        return
    fi
    if [[ $ACTION == queue ]]; then
        if ((DRY == 0)); then
            preflight
            exec 9>/run/lock/vps-tune.lock
            flock -n 9 || die 'Another vps-tune is running'
        fi
        switch_queue
        return
    fi
    if [[ $ACTION == measure ]]; then
        if ((TEST)) || is_container; then die '容器内禁止公网测速；使用手动数据或 JSON 测试。'; fi
        resolve_bandwidth
        printf '\n  本次仅测速；临时工具、配置和缓存将在测速结束后自动清理。\n'
        return
    fi
    if [[ $ACTION == rollback ]]; then
        KERNEL=skip
        preflight
        if ((DRY)); then rollback; return; fi
        exec 9>/run/lock/vps-tune.lock
        flock -n 9 || die 'Another vps-tune is running'
        rollback
        return
    fi
    if ((DRY == 0)); then
        preflight
        exec 9>/run/lock/vps-tune.lock
        flock -n 9 || die 'Another vps-tune is running'
    fi
    resolve_rtt
    resolve_bandwidth
    choose_plan
    if ((REVIEW == 0)); then
        log "Plan: Debian $VERSION_ID ($CODENAME), kernel=${PACKAGE:-skip}, network=BBR+${QDISC^^}, nofile=$NOFILE, RAM=${MEM_MIB}MiB, buffer ceiling=${BUFFER}MiB"
        if ((SMART)); then log "$(buffer_plan_description)"; fi
        show_buffer_notice
    elif ((DRY)); then
        show_tuning_plan
        show_buffer_notice
    fi
    if ((SMART)); then
        if [[ $SMART_PROFILE == asia || $SMART_PROFILE == overseas ]] && [[ -n $RTT_MS ]]; then warn '经验表模式不使用 RTT；如需按 RTT 计算，请选择 BDP 方案。'; fi
    fi
    if ((DRY)); then
        log 'DRY RUN: no changes. Apply also checks container/GRUB/Secure Boot/DKMS/free space and signed APT dependencies.'
        return
    fi
    if ((REVIEW)); then
        if ! review_tuning_plan; then log '预览结束，未写入调优配置。'; return; fi
    fi
    init_state
    if ! command -v sysctl >/dev/null || ! command -v modprobe >/dev/null || ! command -v tc >/dev/null; then
        apt_update
        apt_install procps kmod iproute2
    fi
    install_kernel
    configure_limits
    configure_network
    apply_runtime
    if ((TEST)); then
        warn 'CONTAINER TEST finished. This does not prove kernel boot, host sysctls or throughput gains'
    else
        show_completion
        if ((REBOOT)); then systemctl reboot; fi
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
