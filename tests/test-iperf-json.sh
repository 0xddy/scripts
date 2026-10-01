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
timeout() { printf '%s\n' "$IPERF_FIXTURE"; }
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
timeout() { return 124; }
if (shape_sample timeout 530); then echo 'iperf timeout accepted' >&2; exit 1; fi
SHAPE_SAMPLE_COUNT=28
if (shape_sample over-budget 530); then echo 'Sample limit ignored' >&2; exit 1; fi
printf 'PASS iperf3 JSON calculations, malformed data rejection, timeout and sample budget\n'
