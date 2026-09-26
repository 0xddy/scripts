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
SMART_WANTED_MIB=
SMART_BDP_MIB=
TMP=
PACKAGE=
JQ_BIN=
SPEEDTEST_ROOT=
SPEEDTEST_CMD=()

log() { printf '[vps-tune] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z $TMP ]] || rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
on_error() { local rc=$1 line=$2; printf '[ERROR] line %s, exit %s. Inspect output; backup: %s\n' "$line" "$rc" "$STATE" >&2; exit "$rc"; }
trap 'on_error "$?" "$LINENO"' ERR

usage() {
    cat <<'EOF'
Usage: bash vps-tune.sh                    # Chinese interactive menu
       bash vps-tune.sh [menu|apply|check|rollback|measure] [options]
  --review                Show the calculated plan, then ask apply/preview/cancel.
  --kernel lts|main|skip    Default: lts. Debian 12 supports LTS only.
  --cpu-level auto|v1|v2|v3  Auto chooses the level supported by EVERY CPU.
  --nofile NUMBER          Global soft/hard limit; 65536..1048576.
  --buffer-mib auto|4|8|16|32|64  Per-socket maximum, not initial allocation.
  --smart-bandwidth        Opt in to bandwidth-aware buffers (default: BDP).
  --smart-profile bdp|asia-bdp|overseas-bdp|asia|overseas
                          Region BDP: planning RTT 100/200ms. asia/overseas: tables.
  --bandwidth-mbps NUMBER  Target bottleneck/egress bandwidth, decimal Mbit/s.
  --rtt-ms NUMBER          Representative TCP RTT; alternative to --auto-rtt.
  --auto-rtt               Probe mainland TCP RTT; use P75 of valid site medians.
  --speedtest-json FILE    Import an existing Ookla JSON result (bytes/sec).
  --speedtest              Run a temporary isolated official Ookla CLI once.
  --accept-speedtest-terms Explicitly accept Ookla license/GDPR for this run.
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
            menu|apply|check|rollback|measure) ACTION=$1; shift ;;
            --kernel|--cpu-level|--nofile|--buffer-mib|--smart-profile|--bandwidth-mbps|--rtt-ms|--speedtest-json)
                (($# >= 2)) || die "Missing value for $1"
                case $1 in
                    --kernel) KERNEL=$2 ;; --cpu-level) CPU=$2 ;;
                    --nofile) NOFILE=$2 ;; --buffer-mib) BUFFER=$2 ;;
                    --smart-profile) SMART_PROFILE=$2 ;;
                    --bandwidth-mbps) BANDWIDTH=$2 ;;
                    --rtt-ms) RTT_MS=$2 ;;
                    --speedtest-json) SPEEDTEST_JSON=$2 ;;
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
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [[ $KERNEL =~ ^(lts|main|skip)$ ]] || die 'Invalid --kernel'
    [[ $CPU =~ ^(auto|v1|v2|v3)$ ]] || die 'Invalid --cpu-level'
    if [[ ! $NOFILE =~ ^[1-9][0-9]{4,6}$ ]] || ((NOFILE < 65536 || NOFILE > 1048576)); then die 'Invalid --nofile'; fi
    [[ $BUFFER =~ ^(auto|4|8|16|32|64)$ ]] || die 'Invalid --buffer-mib'
    if ((TEST && REBOOT)); then die 'Container tests cannot reboot'; fi
    if [[ $ACTION != apply ]] && ((REBOOT)); then die 'Reboot flag requires apply'; fi
    if ((REVIEW)) && [[ $ACTION != apply ]]; then die '--review requires apply'; fi
    if [[ $ACTION == measure ]]; then
        if [[ -n $BANDWIDTH || -n $SPEEDTEST_JSON || -n $RTT_MS ]] || ((RTT_AUTO)); then die 'measure only accepts real Speedtest options'; fi
        SMART=1; SPEEDTEST=1; SMART_PROFILE=asia
    fi
    validate_smart_args
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

# Independent implementation inspired by Actions-bbr-v3's bandwidth/region
# tables; BDP profiles also use RTT and apply conservative memory ceilings.
# Input/output units: RAM MiB -> maximum per-socket buffer MiB.
smart_memory_cap_mib() {
    local memory=$1
    if ((memory < 512)); then echo 4
    elif ((memory < 1024)); then echo 8
    elif ((memory < 2048)); then echo 16
    elif ((memory < 4096)); then echo 32
    else echo 64; fi
}

# Emits: chosen_MiB memory_cap_MiB wanted_MiB BDP_MiB.
# 2 x BDP plus upward tier rounding is a starting heuristic, not an optimum.
smart_buffer_plan() {
    local bandwidth=$1 rtt=${2:-0} profile=$3 memory=$4 cap
    cap=$(smart_memory_cap_mib "$memory")
    awk -v bw="$bandwidth" -v rtt="$rtt" -v mode="$profile" -v cap="$cap" '
    BEGIN {
        bdp=bw*1000000/8*rtt/1000/1048576;
        if (mode=="bdp" || mode=="asia-bdp" || mode=="overseas-bdp") {
            n=split("4 8 12 16 24 32 48 64", tiers, " ");
            wanted=int(2*bdp); if (wanted<2*bdp) wanted++;
            for (i=1;i<=n;i++) if (tiers[i]>=2*bdp) {wanted=tiers[i]; break}
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

probe_cn_site() {
    local host=$1 output=$2 attempt metrics address dns connect
    for ((attempt=1; attempt<=3; attempt++)); do
        # Disable curlrc/proxies; DNS time is excluded from the TCP interval.
        # HTTP failures after a successful handshake do not erase its RTT.
        metrics=$(curl -q --noproxy '*' -4 -s --head --connect-timeout 2 \
            --max-time 3 -o /dev/null -w '%{remote_ip} %{time_namelookup} %{time_connect}' \
            "http://$host/") || true
        read -r address dns connect <<< "$metrics"
        [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        case $address in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;; esac
        [[ $dns =~ ^[0-9]+(\.[0-9]+)?$ && $connect =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        awk -v ip="$address" -v dns="$dns" -v connected="$connect" 'BEGIN {
            rtt=(connected-dns)*1000;
            if (rtt>0 && rtt<=5000) printf "%s %.3f\n", ip, rtt;
        }'
    done > "$output"
}

resolve_rtt() {
    ((RTT_AUTO)) || return 0
    command -v curl >/dev/null || die '大陆 RTT 探测需要已有 curl；也可选择区域参考值或手填 RTT。'
    ensure_tmp
    local directory=$TMP/cn-rtt region isp label host key result address median count
    local successful=0 failed=0 regions=0 provider_count=0 pid
    local -a jobs=()
    local -A seen=() covered_region=() covered_isp=()
    mkdir -p "$directory"
    log '探测北京、上海、广东的电信/联通/移动公开测点：每点 3 次 TCP 连接，约 10 秒。'
    while read -r region isp label; do
        host="$region-${isp,,}-v4.ip.zstaticcdn.com"
        probe_cn_site "$host" "$directory/$region-$isp" &
        jobs+=("$!")
    done < <(cn_rtt_targets)
    for pid in "${jobs[@]}"; do wait "$pid" || true; done
    : > "$directory/medians"
    while read -r region isp label; do
        key=$region-$isp
        result=$(sort -k2,2n "$directory/$key" | awk '
            NF==2 {ip[NR]=$1; value[NR]=$2; n++}
            END {
                if(n<2) exit;
                mid=(n%2 ? value[int(n/2)+1] : (value[n/2]+value[n/2+1])/2);
                printf "%s %.3f %d\n", ip[int(n/2)+1], mid, n;
            }')
        if [[ -z $result ]]; then
            printf '  %-12s 无有效样本（至少需 2/3 次连接成功）\n' "$label"
            failed=$((failed + 1)); continue
        fi
        read -r address median count <<< "$result"
        if [[ -n ${seen[$address]:-} ]]; then
            printf '  %-12s %s ms，测点 IP 重复，不重复计权\n' "$label" "$median"
            continue
        fi
        seen[$address]=1; covered_region[$region]=1; covered_isp[$isp]=1
        successful=$((successful + 1))
        printf '%s\n' "$median" >> "$directory/medians"
        printf '  %-12s %s ms（%s/3；%s）\n' "$label" "$median" "$count" "$address"
    done < <(cn_rtt_targets)
    regions=${#covered_region[@]}; provider_count=${#covered_isp[@]}
    if ((successful < 3 || regions < 2 || provider_count < 3)); then
        die "大陆 RTT 样本覆盖不足（有效 $successful/9；地区 $regions/3；运营商 $provider_count/3）。未使用猜测值，请选择区域参考值或手填 RTT。"
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
        { timeout --kill-after=5 180 "${SPEEDTEST_CMD[@]}" --accept-license --accept-gdpr --ca-certificate=/etc/ssl/certs/ca-certificates.crt --progress=no --format=json > "$TMP/speedtest.json"; } 2> "$TMP/speedtest-error.log" || speedtest_status=$?
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
    if ((SMART)); then
        read -r BUFFER SMART_CAP_MIB SMART_WANTED_MIB SMART_BDP_MIB < <(smart_buffer_plan "$BANDWIDTH" "$RTT_MS" "$SMART_PROFILE" "$MEM_MIB")
    elif [[ $BUFFER == auto ]]; then
        BUFFER=4
        ((MEM_MIB < 1024)) || BUFFER=8
        ((MEM_MIB < 2048)) || BUFFER=16
        ((MEM_MIB < 4096)) || BUFFER=32
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
    install -d -m 700 "$STATE" "$STATE/original" "$STATE/expected"
    touch "$STATE/manifest" "$STATE/runtime.before"
}

track_file() {
    local path=$1
    if grep -Fxq "$path" "$STATE/manifest"; then
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

configure_network() {
    write_file "$SYSCTL" <<EOF
# Managed by vps-tune. Values are ceilings, not preallocated buffers.
# Buffer plan: $(buffer_plan_description)
fs.file-max = $FS_MAX
fs.nr_open = $NR_OPEN
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 8192
net.core.rmem_max = $BUF_BYTES
net.core.wmem_max = $BUF_BYTES
net.ipv4.tcp_rmem = 4096 131072 $BUF_BYTES
net.ipv4.tcp_wmem = 4096 16384 $BUF_BYTES
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1
# Optional until the new kernel boots. The sysctl algorithm name is bbr,
# including on XanMod releases carrying BBRv3; it is not named bbr3.
-net.core.default_qdisc = cake
-net.ipv4.tcp_congestion_control = bbr
EOF
    write_file /etc/modules-load.d/90-vps-tune.conf <<'EOF'
tcp_bbr
sch_cake
EOF
}

buffer_plan_description() {
    if ((SMART)); then
        local basis=${RTT_SOURCE:-manual}
        case $SMART_PROFILE in
            *-bdp) basis='region-planning-not-measured' ;;
            asia|overseas) basis=not-used ;;
        esac
        printf 'smart/%s; source=%s; upload/target=%s Mbit/s; download=%s Mbit/s; RTT=%s ms; RTT-basis=%s; BDP=%s MiB; wanted=%s MiB; RAM-cap=%s MiB; selected=%s MiB' \
            "$SMART_PROFILE" "$BANDWIDTH_SOURCE" "$BANDWIDTH" "${DOWNLOAD_MBPS:-not-measured}" "${RTT_MS:-not-used}" "$basis" "$SMART_BDP_MIB" "$SMART_WANTED_MIB" "$SMART_CAP_MIB" "$BUFFER"
    else
        printf 'standard; selected=%s MiB' "$BUFFER"
    fi
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
    modprobe sch_cake || warn 'sch_cake unavailable in the running kernel; retry after XanMod reboot'
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

check_cake_qdiscs() {
    local interface output bad=0
    local -a interfaces=()
    if ! command -v ip >/dev/null || ! command -v tc >/dev/null; then
        warn 'ip/tc unavailable; actual CAKE queues are unverified'; return 2
    fi
    mapfile -t interfaces < <({ ip -o -4 route show default; ip -o -6 route show default; } |
        awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
    if ((${#interfaces[@]} == 0)); then warn 'No default-route interface; CAKE is unverified'; return 2; fi
    for interface in "${interfaces[@]}"; do
        log "Actual egress qdisc: $interface"
        if ! output=$(tc qdisc show dev "$interface"); then bad=1; continue; fi
        printf '%s\n' "$output"
        # mq is a valid root when every transmit leaf is cake. ingress/clsact
        # are unrelated hooks; don't count them as egress queue disciplines.
        if ! awk '
            $1=="qdisc" && $2!="ingress" && $2!="clsact" {
                if ($2=="cake") cake++;
                else if ($2!="mq") bad=1;
            }
            END {exit !(cake>0 && !bad)}' <<< "$output"; then
            warn "$interface is not using CAKE on all egress queues; reboot and inspect network-manager overrides (noqueue/veth ignore the global default)"
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
    if [[ $(cat /proc/1/comm) == systemd ]]; then
        systemctl show -p DefaultLimitNOFILE -p DefaultLimitNOFILESoft
        local target
        target=$(awk -F= '/^DefaultLimitNOFILE=/ {split($2,a,":"); print a[1]}' /etc/systemd/system.conf.d/$TAG)
        for key in DefaultLimitNOFILE DefaultLimitNOFILESoft; do
            actual=$(systemctl show -p "$key" --value)
            [[ $actual == "$target" ]] || bad=1
        done
    else
        warn 'No systemd PID 1; effective system defaults and boot are unverified'
        bad=1
    fi
    check_cake_qdiscs || bad=1
    log "Current shell limit: soft=$(ulimit -Sn), hard=$(ulimit -Hn). Re-login for PAM limits."
    if ((bad)); then warn 'CHECK: differences/pending/unverified items exist (exit 2)'; return 2; fi
    log 'CHECK: inspected runtime values and default-route CAKE queues match. Verify new login sessions separately.'
}

rollback() {
    [[ -s $STATE/manifest ]] || die 'No tracked configuration to restore'
    local path key value archived
    while IFS= read -r path; do
        if [[ -f $STATE/expected$path ]]; then
            if [[ ! -f $path || -L $path ]] || ! cmp -s "$path" "$STATE/expected$path"; then die "Rollback would overwrite a later edit: $path. Back it up/reconcile first"; fi
        fi
    done < "$STATE/manifest"
    ((DRY == 0)) || { log 'Would restore the following paths:'; cat "$STATE/manifest"; return 0; }
    while IFS= read -r path; do
        if [[ -f $STATE/original$path ]]; then cp -a -- "$STATE/original$path" "$path"; else rm -f -- "$path"; fi
    done < "$STATE/manifest"
    if ((TEST == 0)); then
        while IFS='=' read -r key value; do
            [[ -n $key ]] || continue
            sysctl -w "$key=$value" || warn "Could not restore live sysctl: $key; reboot and verify"
        done < "$STATE/runtime.before"
        systemctl daemon-reload
        systemctl daemon-reexec
        if grep -qF '/etc/default/grub.d/90-vps-tune.cfg' "$STATE/manifest"; then update-grub; fi
    fi
    archived="${STATE}.rolled-back.$(date +%Y%m%d%H%M%S).$$"
    mv -- "$STATE" "$archived"
    log "Configuration restored; audit backup: $archived"
    warn 'Packages/kernels remain installed; running kernel/process limits remain until reboot/restart. To revert kernel, choose the Debian kernel in GRUB first'
}

menu_read() {
    local prompt=$1 default=${2:-}
    printf '%s' "$prompt" >&2
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
                menu_read '常规缓冲档：auto / 4 / 8 / 16 / 32 / 64：' auto || return 0
                if [[ $REPLY =~ ^(auto|4|8|16|32|64)$ ]]; then MENU_BUFFER=$REPLY; else printf '无效缓冲档位。\n'; fi ;;
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

interactive_menu() {
    local SCRIPT_SELF MENU_NOFILE=$NOFILE MENU_KERNEL=$KERNEL
    local MENU_CPU=$CPU MENU_BUFFER=$BUFFER MENU_DKMS=$ALLOW_DKMS
    local -a MENU_ARGS=()
    SCRIPT_SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -f $SCRIPT_SELF ]] || die '请先将脚本保存为本地文件，再打开菜单。'
    while true; do
        printf '\n====== Debian %s / VPS 系统优化 ======\n' "$VERSION_ID"
        printf '当前内核：%s\n全局文件句柄默认值：%s\n' "$(uname -r)" "$MENU_NOFILE"
        ((TEST == 0)) || printf '【Docker 测试模式】不改宿主参数、不重启、不发起公网测速。\n'
        printf '网络目标：BBR + CAKE（持久化配置，重启后检查网卡队列）\n'
        printf '1. 完整配置（XanMod + BBR/CAKE + 文件句柄）\n'
        printf '2. 常规调优（BBR/CAKE，保留当前内核）\n3. 智能带宽调优（保留当前内核）\n'
        printf '4. 临时测速（只测速，不修改调优配置）\n5. 检查实际生效状态\n'
        printf '6. 回滚调优配置\n7. 参数设置\n8. 重启系统\n0. 退出\n'
        menu_read '请选择 [0]：' 0 || break
        case $REPLY in
            1|2)
                local choice=$REPLY
                menu_base_args
                if [[ $choice == 1 ]]; then MENU_ARGS+=(--kernel "$MENU_KERNEL"); else MENU_ARGS+=(--kernel skip); fi
                MENU_ARGS+=(--buffer-mib "$MENU_BUFFER")
                menu_run "${MENU_ARGS[@]}" ;;
            3) menu_smart ;;
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
            8)
                if ((TEST)) || is_container; then printf '容器内禁止重启宿主系统。\n'; continue; fi
                menu_read '重启会断开 SSH；输入 REBOOT 确认：' || break
                if [[ $REPLY == REBOOT ]]; then systemctl reboot; return; else printf '未执行重启。\n'; fi ;;
            0) break ;;
            *) printf '请选择 0～8。\n' ;;
        esac
    done
    printf '已退出菜单。\n'
}

main() {
    if (($# == 0)); then
        [[ -t 0 ]] || die '交互菜单需要终端；请运行 sudo bash vps-tune.sh。自动化请显式使用 apply/check/rollback。'
        set -- menu
    fi
    parse_args "$@"
    check_os
    if [[ $ACTION == check ]]; then
        # A pending verification (2) is a normal check result, not an ERR trap.
        if check_status; then exit 0; else exit "$?"; fi
    fi
    ((EUID == 0)) || die 'Run as root'
    if [[ $ACTION == menu ]]; then interactive_menu; return; fi
    if [[ $ACTION == measure ]]; then
        if ((TEST)) || is_container; then die '容器内禁止公网测速；使用手动数据或 JSON 测试。'; fi
        resolve_bandwidth
        printf '\n测速结果：上传 %s Mbit/s，下载 %s Mbit/s。\n' "$BANDWIDTH" "$DOWNLOAD_MBPS"
        printf '未修改系统调优配置；临时工具、配置和缓存将在退出时清理。\n'
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
    log "Plan: Debian $VERSION_ID ($CODENAME), kernel=${PACKAGE:-skip}, network=BBR+CAKE, nofile=$NOFILE, RAM=${MEM_MIB}MiB, buffer ceiling=${BUFFER}MiB"
    if ((SMART)); then
        log "$(buffer_plan_description)"
        if ((SMART_WANTED_MIB > SMART_CAP_MIB)); then warn 'Requested buffer exceeds memory cap; capped. This may limit a high-BDP flow'; fi
        if [[ $SMART_PROFILE == asia || $SMART_PROFILE == overseas ]] && [[ -n $RTT_MS ]]; then warn 'Region-table mode does not use RTT in its calculation; choose bdp to use RTT'; fi
    fi
    if ((DRY)); then
        log 'DRY RUN: no changes. Apply also checks container/GRUB/Secure Boot/DKMS/free space and signed APT dependencies.'
        return
    fi
    if ((REVIEW)); then
        printf '\n以上为本次方案。现有进程的文件限制需重启服务/重新登录后生效。\n'
        printf '1. 应用方案\n2. 仅预览，返回菜单\n0. 取消\n'
        menu_read '请选择 [2]：' 2 || { log '已取消，未写入调优配置。'; return; }
        [[ $REPLY == 1 ]] || { log '预览结束，未写入调优配置。'; return; }
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
    log 'Configuration installed. First-run originals retained for rollback.'
    if ((TEST)); then
        warn 'CONTAINER TEST finished. This does not prove kernel boot, host sysctls or throughput gains'
    else
        warn 'Reboot required for XanMod and all newly started processes/sessions. Existing sessions/services retain their limits'
        warn 'BBR + CAKE configured persistently. CAKE applies to new qdiscs after reboot; run menu check to verify the actual interface queues'
        if ((REBOOT)); then systemctl reboot; fi
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
