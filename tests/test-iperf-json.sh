#!/usr/bin/env bash
# jq is the only extra test dependency; iperf3 and public traffic are mocked.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
target_script=${1:-${TARGET_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../vps-tune.sh}}
JQ_TEST_BIN=${2:-$(type -P jq)}
saved_path=$PATH
# shellcheck source=/dev/null
source "$target_script"
PATH=$saved_path
trap - EXIT ERR INT TERM
SHAPE_LOG_DIR=$(mktemp -d)
trap 'rm -rf -- "$SHAPE_LOG_DIR"' EXIT
SHAPE_SAMPLE_COUNT=0
SHAPE_IFACE=test0; SWEEP_ADDRESS=192.0.2.1
jq() { "$JQ_TEST_BIN" "$@"; }
IPERF_EXIT=0
IPERF_STDERR=''
timeout() {
    printf '%s\n' "$IPERF_FIXTURE"
    [[ -z $IPERF_STDERR ]] || printf '%s\n' "$IPERF_STDERR" >&2
    return "$IPERF_EXIT"
}
IPERF_FIXTURE='{"start":{"tcp_mss_default":1460},"end":{"sum_sent":{"bytes":625000000,"retransmits":50},"sum_received":{"bits_per_second":499000000}}}'
shape_sample valid 530
[[ $SHAPE_SAMPLE_GOODPUT == 499.0000 && $SHAPE_SAMPLE_RATIO == 0.011680 && $SHAPE_SAMPLE_COUNT == 1 ]]
shape_clean_sample
IPERF_FIXTURE='{"start":{"tcp_mss_default":1460},"end":{"sum_sent":{"bytes":625000000,"retransmits":5000},"sum_received":{"bits_per_second":499000000}}}'
shape_sample high-retransmissions 530
if shape_clean_sample; then echo 'High retransmission fixture classified clean' >&2; exit 1; fi
for IPERF_FIXTURE in \
    '{"error":"server unavailable"}' \
    '{"start":{"tcp_mss_default":1460},"end":{"sum_sent":{"bytes":625000000},"sum_received":{"bits_per_second":499000000}}}' \
    '{"start":{"tcp_mss_default":0},"end":{"sum_sent":{"bytes":625000000,"retransmits":50},"sum_received":{"bits_per_second":499000000}}}' \
    '{"start":{"tcp_mss_default":1460},"end":{"sum_sent":{"bytes":0,"retransmits":50},"sum_received":{"bits_per_second":499000000}}}' \
    '{"start":{"tcp_mss_default":1460},"end":{"sum_sent":{"bytes":625000000,"retransmits":50},"sum_received":{"bits_per_second":"499000000"}}}' \
    'not json'; do
    if (shape_sample malformed 530); then echo 'Invalid iperf fixture accepted' >&2; exit 1; fi
done
# Remote errors must be visible without executing their contents, injecting
# extra log lines, terminal escapes or Unicode direction/control characters.
IPERF_EXIT=1
IPERF_STDERR='private stderr diagnostic is retained only on disk'
raw_error=$'connection refused\nFORGED LINE\r\t\e[31m\x7f\xc2\x9b\xe2\x80\xae'
# Literal command text tests that the displayed remote message is never run.
# shellcheck disable=SC2016
raw_error+='$(touch '
raw_error+="$SHAPE_LOG_DIR/executed"
raw_error+=')'
IPERF_FIXTURE=$(jq -cn --arg error "$raw_error" '{error:$error}')
if output=$(shape_sample remote-error 530 2>&1); then echo 'Remote error exit accepted' >&2; exit 1; fi
[[ $output == *'iperf3 error: connection refused FORGED LINE'* && $output == *'(exit 1)'* ]]
[[ $output != *$'\e'* && $output != *$'\r'* && $output != *$'\t'* && $output != *$'\x7f'* && $output != *$'\xc2\x9b'* && $output != *$'\xe2\x80\xae'* ]]
[[ $(wc -l <<< "$output") -eq 2 && ! -e $SHAPE_LOG_DIR/executed ]]
[[ $output != *"$IPERF_STDERR"* ]]
[[ $(cat "$SHAPE_LOG_DIR/03-remote-error.json") == "$IPERF_FIXTURE" ]]
[[ $(cat "$SHAPE_LOG_DIR/03-remote-error.json.stderr") == "$IPERF_STDERR" ]]

printf -v long_error '%500s' ''
long_error=${long_error// /x}
IPERF_FIXTURE=$(jq -cn --arg error "$long_error" '{error:$error}')
if output=$(shape_sample long-error 530 2>&1); then echo 'Long remote error accepted' >&2; exit 1; fi
detail=${output%%$'\n'*}
[[ ${#detail} -le 280 && $detail == *'...' ]]

# A zero process exit with JSON.error follows the same sanitized display path;
# raw jq diagnostics are saved separately instead of reaching the terminal.
IPERF_EXIT=0
IPERF_FIXTURE=$(jq -cn --arg error "$raw_error" '{error:$error}')
if output=$(shape_sample json-error 530 2>&1); then echo 'JSON error accepted' >&2; exit 1; fi
[[ $output == *'iperf3 error: connection refused FORGED LINE'* && $output == *'Unsupported/incomplete iperf3 JSON'* ]]
[[ $output != *$'\e'* && $(wc -l <<< "$output") -eq 2 ]]
[[ -s $SHAPE_LOG_DIR/03-json-error.json.parse.stderr ]]

# Diagnostic extraction must never hide the original process error. Invalid
# JSON, missing/non-string errors and multiple JSON documents stay generic.
IPERF_EXIT=7
for IPERF_FIXTURE in 'not json' '{}' '{"error":42}' '{"error":""}' $'{"error":"first"}\n{"error":"second"}'; do
    if output=$(shape_sample unreadable-error 530 2>&1); then echo 'Failed process accepted' >&2; exit 1; fi
    [[ $output == *'(exit 7)'* && $output != *'iperf3 error:'* && $(wc -l <<< "$output") -eq 1 ]]
done
timeout() { return 124; }
if (shape_sample timeout 530); then echo 'iperf timeout accepted' >&2; exit 1; fi
SHAPE_SAMPLE_COUNT=28
if (shape_sample over-budget 530); then echo 'Sample limit ignored' >&2; exit 1; fi
printf 'PASS iperf3 JSON calculations, sanitized bounded diagnostics, preserved failures, timeout and sample budget\n'
