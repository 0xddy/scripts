#!/usr/bin/env bash
# Disposable-container integration and algorithm tests; no Internet speed test.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Disposable Docker container required'; exit 1; }
SCRIPT=${1:-/src/vps-tune.sh}
SCRATCH=$(mktemp -d)
trap 'rm -rf -- "$SCRATCH"' EXIT
passed=0
pass() { printf 'PASS %s\n' "$*"; passed=$((passed + 1)); }
expect_failure() { if "$@" > "$SCRATCH/rejected.log" 2>&1; then cat "$SCRATCH/rejected.log"; echo "Unexpected success: $*"; exit 1; fi; }
plan() { bash -c 'source "$1"; smart_buffer_plan "$2" "$3" "$4" "$5"' _ "$SCRIPT" "$@"; }
expect_plan() {
    local result selected cap wanted _bdp
    result=$(plan "$1" "$2" "$3" "$4")
    read -r selected cap wanted _bdp <<< "$result"
    [[ "$selected $cap $wanted" == "$5" ]] || { echo "Bad plan $*: $result"; exit 1; }
}

shellcheck "$SCRIPT"
bash -n "$SCRIPT"
pass 'Production script syntax and ShellCheck'
expect_plan 1000 10 bdp 8192 '4 64 4'
expect_plan 1000 100 bdp 8192 '24 64 24'
expect_plan 1000 150 bdp 8192 '48 64 48'
expect_plan 1000 300 bdp 8192 '64 64 72'
expect_plan 1000 150 bdp 256 '4 4 48'
expect_plan 1000 150 bdp 512 '8 8 48'
expect_plan 1000 150 bdp 1024 '16 16 48'
expect_plan 1000 150 bdp 2048 '32 32 48'
expect_plan 1000 150 bdp 4096 '48 64 48'
expect_plan 0.5 200 bdp 8192 '4 64 4'
expect_plan 335.54432 100 bdp 8192 '8 64 8'
expect_plan 1000 100 asia-bdp 8192 '24 64 24'
expect_plan 1000 200 overseas-bdp 8192 '48 64 48'
pass 'BDP units, real RTT effect, decimal bandwidth, rounding and RAM caps'

for pair in '499.99 8' '500 12' '999.99 12' '1000 16' '1999.99 16' '2000 24' '4999.99 24' '5000 28' '9999.99 28' '10000 32'; do
    read -r bandwidth expected <<< "$pair"
    expect_plan "$bandwidth" 0 asia 8192 "$expected 64 $expected"
done
for pair in '499.99 16' '500 48' '999.99 48' '1000 64'; do
    read -r bandwidth expected <<< "$pair"
    expect_plan "$bandwidth" 0 overseas 8192 "$expected 64 $expected"
done
expect_plan 1000 0 overseas 256 '4 4 64'
[[ $(plan 1000 10 asia 8192 | cut -d' ' -f1) == $(plan 1000 300 asia 8192 | cut -d' ' -f1) ]]
pass 'All upstream bandwidth thresholds and region mode intentionally ignores RTT'

for bad in 0 -1 100001 NaN 1e3 '1;touch /tmp/injected' ' '; do
    expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --bandwidth-mbps "$bad" --rtt-ms 100
done
for bad in 0 -1 5001 NaN; do
    expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms "$bad"
done
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --bandwidth-mbps 1000
expect_failure bash "$SCRIPT" --dry-run --kernel skip --bandwidth-mbps 1000 --rtt-ms 100
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 100 --buffer-mib 32
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 100 --speedtest-json unused.json
expect_failure bash "$SCRIPT" --container-test --kernel skip --smart-bandwidth --speedtest --rtt-ms 100 --accept-speedtest-terms
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --speedtest --rtt-ms 100 --accept-speedtest-terms
expect_failure bash "$SCRIPT" --kernel skip --smart-bandwidth --speedtest --rtt-ms 100
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --smart-profile asia-bdp --bandwidth-mbps 1000 --rtt-ms 150
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --smart-profile overseas-bdp --bandwidth-mbps 1000 --rtt-ms 150
pass 'Malformed/missing/ambiguous inputs and unattended real-speedtest guards'

cat > "$SCRATCH/result.json" <<'EOF'
{"type":"result","ping":{"latency":1},"upload":{"bandwidth":125000000},"download":{"bandwidth":250000000}}
EOF
bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --speedtest-json "$SCRATCH/result.json" --rtt-ms 150 > "$SCRATCH/preview"
grep -q 'upload/target=1000.000000 Mbit/s; download=2000.000000 Mbit/s; RTT=150 ms' "$SCRATCH/preview"
grep -q 'BDP=17.881393 MiB; wanted=48 MiB' "$SCRATCH/preview"
sed 's/"latency":1/"latency":999/' "$SCRATCH/result.json" > "$SCRATCH/different-ping.json"
bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --speedtest-json "$SCRATCH/different-ping.json" --rtt-ms 150 > "$SCRATCH/preview2"
cmp "$SCRATCH/preview" "$SCRATCH/preview2"
pass 'Ookla bytes/sec -> decimal Mbit/s; Speedtest ping never changes the calculation'

for json in '{}' '[]' '{broken' '{"type":"result","upload":{"bandwidth":0},"download":{"bandwidth":10}}' \
    '{"type":"result","upload":{"bandwidth":"125000000"},"download":{"bandwidth":10}}' \
    '{"type":"result","upload":{"bandwidth":12500000001},"download":{"bandwidth":10}}'; do
    printf '%s\n' "$json" > "$SCRATCH/bad.json"
    expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --speedtest-json "$SCRATCH/bad.json" --rtt-ms 150
done
cat "$SCRATCH/result.json" "$SCRATCH/result.json" > "$SCRATCH/two.json"
expect_failure bash "$SCRIPT" --dry-run --kernel skip --smart-bandwidth --speedtest-json "$SCRATCH/two.json" --rtt-ms 150
pass 'Malformed, incomplete, string-valued, out-of-range and multiple JSON results are rejected'

if [[ -s /var/lib/singbox-tune/manifest ]]; then bash "$SCRIPT" rollback --container-test; fi
sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem > "$SCRATCH/live.before"
bash "$SCRIPT" --container-test --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 150
cp /etc/sysctl.d/99-zz-singbox-tune.conf "$SCRATCH/smart.sysctl"
grep -q '^# Buffer plan: smart/bdp' "$SCRATCH/smart.sysctl"
grep -q '^net.ipv4.tcp_rmem = 4096 131072 ' "$SCRATCH/smart.sysctl"
grep -q '^net.ipv4.tcp_wmem = 4096 16384 ' "$SCRATCH/smart.sysctl"
awk '/^net.core.rmem_max/ {r=$3} /^net.core.wmem_max/ {w=$3} /^net.ipv4.tcp_rmem/ {tr=$5} /^net.ipv4.tcp_wmem/ {tw=$5} END {exit !(r>0 && r==w && r==tr && r==tw)}' "$SCRATCH/smart.sysctl"
if grep -q '^net.ipv4.tcp_slow_start_after_idle\|^net.ipv4.tcp_limit_output_bytes' "$SCRATCH/smart.sysctl"; then
    echo 'Unexpected unrelated TCP tuning'; exit 1
fi
bash "$SCRIPT" --container-test --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 150
cmp /etc/sysctl.d/99-zz-singbox-tune.conf "$SCRATCH/smart.sysctl"
bash "$SCRIPT" --container-test --kernel skip --smart-bandwidth --smart-profile asia --bandwidth-mbps 700
grep -q '^# Buffer plan: smart/asia' /etc/sysctl.d/99-zz-singbox-tune.conf
bash "$SCRIPT" --container-test --kernel skip
grep -q '^# Buffer plan: standard' /etc/sysctl.d/99-zz-singbox-tune.conf
bash "$SCRIPT" rollback --container-test
[[ ! -e /etc/sysctl.d/99-zz-singbox-tune.conf ]]
sysctl -n net.ipv4.tcp_rmem net.ipv4.tcp_wmem > "$SCRATCH/live.after"
cmp "$SCRATCH/live.before" "$SCRATCH/live.after"
pass 'Smart apply/reapply, mode changes, return to standard, rollback; no live sysctl changes'

# Exercise the command/JSON adapter; replace only the runtime preparation
# function with a local executable, never install a fake global CLI.
cat > "$SCRATCH/cli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$ADAPTER_RECORD/args"
if [ "$ADAPTER_FAIL" = 1 ]; then echo 'Fixture measurement failure' >&2; exit 3; fi
printf '%s\n' '{"type":"result","upload":{"bandwidth":125000000},"download":{"bandwidth":250000000}}'
EOF
chmod 755 "$SCRATCH/cli"
cat > "$SCRATCH/adapter.sh" <<'EOF'
source "$1"
prepare_isolated_speedtest() {
    ensure_tmp
    printf '%s\n' "$TMP" > "$ADAPTER_RECORD/temp.path"
    SPEEDTEST_CMD=("$ADAPTER_RECORD/cli")
}
SMART=1; SPEEDTEST=1
resolve_bandwidth
[[ $BANDWIDTH == 1000.000000 && $BANDWIDTH_SOURCE == ookla-live ]]
EOF
export ADAPTER_RECORD=$SCRATCH ADAPTER_FAIL=0
bash "$SCRATCH/adapter.sh" "$SCRIPT"
grep -qx -- '--accept-license --accept-gdpr --ca-certificate=/etc/ssl/certs/ca-certificates.crt --format=json' "$SCRATCH/args"
[[ ! -e $(cat "$SCRATCH/temp.path") ]]
export ADAPTER_FAIL=1
expect_failure bash "$SCRATCH/adapter.sh" "$SCRIPT"
[[ ! -e $(cat "$SCRATCH/temp.path") ]]
pass 'Live adapter fixture: correct flags, cleanup, failure has no guessed fallback'
printf 'SMART RESULT: %s groups passed; no real Ookla speed test was run\n' "$passed"
