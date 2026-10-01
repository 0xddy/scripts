#!/usr/bin/env bash
# Run in disposable Docker with --network none --cap-add NET_ADMIN.
# Uses real isolated tc; no public traffic, host sysctl or module loads.
# Usage: bash tests/test-tcpfit-queue.sh [vps-tune.sh] [absolute/jq/path]
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
[[ -f /.dockerenv && $EUID == 0 ]] || { printf 'Disposable root Docker container required\n' >&2; exit 1; }
[[ $(ip -o link show | wc -l) == 1 ]] || { printf 'Use Docker --network none\n' >&2; exit 1; }
target_script=${1:-$(dirname "${BASH_SOURCE[0]}")/../vps-tune.sh}
JQ_TEST_BIN=${2:-$(type -P jq)}
[[ $JQ_TEST_BIN == /* && -x $JQ_TEST_BIN ]] || { printf 'Supply an absolute executable jq path\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$target_script"
trap - EXIT ERR INT TERM
jq() { "$JQ_TEST_BIN" "$@"; }
modprobe() { :; }
scratch=$(mktemp -d)
trap 'ip link del tcfq-review 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
ip link add tcfq-review type dummy
ip link set tcfq-review up
tc qdisc replace dev tcfq-review root handle 1: htb default 10
tc class replace dev tcfq-review parent 1: classid 1:10 htb rate 1037mbit ceil 1037mbit burst 518500 cburst 518500 quantum 1514
tc qdisc replace dev tcfq-review parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate 1037mbit
tcpfit_queue_capture tcfq-review "$scratch/standard"
[[ $TCPFIT_MIGRATION_RATE == 1037 ]]
tcpfit_queue_restore tcfq-review "$scratch/standard"
printf 'PASS standard 1037 tree\n'
tc qdisc change dev tcfq-review parent 1:10 handle 10: fq quantum 4096 initial_quantum 24576 buckets 2048 orphan_mask 511 low_rate_threshold 2mbit refill_delay 11ms timer_slack 25000ns horizon 4s horizon_cap ce_threshold 50ms nopacing
tcpfit_queue_capture tcfq-review "$scratch/custom"
tcpfit_queue_restore tcfq-review "$scratch/custom"
printf 'PASS custom FQ exact restore\n'
tc qdisc change dev tcfq-review parent 1:10 handle 10: fq low_rate_threshold 0bit
tcpfit_queue_capture tcfq-review "$scratch/zero-low"
tcpfit_queue_restore tcfq-review "$scratch/zero-low"
printf 'PASS absent zero low_rate_threshold\n'
mkdir "$scratch/new" "$scratch/unknown" "$scratch/bad-bands"
cp "$scratch/standard/class.json" "$scratch/new/class.json"
jq 'map(if .kind=="fq" then .options += {bands:3,"priomap ":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1],"weights ":[9,3,1],offload_horizon:0} else . end)' "$scratch/standard/qdisc.json" > "$scratch/new/qdisc.json"
tcpfit_queue_parse tcfq-review "$scratch/new"
mapfile -d '' -t argv < "$scratch/new/fq.args"
[[ " ${argv[*]} " == *' bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 weights 9 3 1 offload_horizon 0us '* ]]
printf 'PASS new kernel FQ fields parser\n'
cp "$scratch/standard/class.json" "$scratch/unknown/class.json"
jq 'map(if .kind=="fq" then .options.secret=1 else . end)' "$scratch/standard/qdisc.json" > "$scratch/unknown/qdisc.json"
if tcpfit_queue_parse tcfq-review "$scratch/unknown"; then exit 1; fi
cp "$scratch/standard/class.json" "$scratch/bad-bands/class.json"
jq 'map(if .kind=="fq" then .options += {bands:3,"priomap":[3,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1]} else . end)' "$scratch/standard/qdisc.json" > "$scratch/bad-bands/qdisc.json"
if tcpfit_queue_parse tcfq-review "$scratch/bad-bands"; then exit 1; fi
printf 'PASS unknown and invalid options rejected\n'
class_text='class htb 1:10 root leaf 10: prio 0 quantum 1514 rate 1.037Gbit ceil 1037000Kbit linklayer ethernet burst 518500b/1 mpu 0b cburst 518500b/1 mpu 0b level 0'
[[ $(tcpfit_queue_class_json "$class_text" | jq -r '.[0].rate') == 129625000 ]]
[[ $(tcpfit_queue_class_json "$class_text" | jq -r '.[0].ceil') == 129625000 ]]
if tcpfit_queue_class_json "$class_text unknown 1"; then exit 1; fi
if tcpfit_queue_class_json "$class_text
$class_text"; then exit 1; fi
printf 'PASS Debian 12 detailed class adapter units and strict rejection\n'
