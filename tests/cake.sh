#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Disposable Docker required'; exit 1; }
SCRIPT=${1:-/src/vps-tune.sh}
SCRATCH=$(mktemp -d)
trap 'rm -rf -- "$SCRATCH"' EXIT
if [[ -s /var/lib/singbox-tune/manifest ]]; then bash "$SCRIPT" rollback --container-test; fi
sysctl -n net.ipv4.tcp_congestion_control > "$SCRATCH/before"
tc qdisc show >> "$SCRATCH/before"
bash "$SCRIPT" apply --container-test --kernel skip
grep -qx -- '-net.core.default_qdisc = cake' /etc/sysctl.d/99-zz-singbox-tune.conf
grep -qx -- '-net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/99-zz-singbox-tune.conf
printf 'tcp_bbr\nsch_cake\n' > "$SCRATCH/modules"
cmp "$SCRATCH/modules" /etc/modules-load.d/90-singbox-tune.conf
bash "$SCRIPT" apply --container-test --kernel skip --smart-bandwidth --bandwidth-mbps 1000 --rtt-ms 150
grep -qx -- '-net.core.default_qdisc = cake' /etc/sysctl.d/99-zz-singbox-tune.conf
cmp "$SCRATCH/modules" /etc/modules-load.d/90-singbox-tune.conf
bash "$SCRIPT" rollback --container-test
sysctl -n net.ipv4.tcp_congestion_control > "$SCRATCH/after"
tc qdisc show >> "$SCRATCH/after"
cmp "$SCRATCH/before" "$SCRATCH/after"
echo 'PASS Standard/smart persist BBR+CAKE and boot modules; rollback; no live host qdisc changes'

cat > "$SCRATCH/check.sh" <<'EOF'
source "$1"
fixture=$2
ip() {
    [[ $fixture != no-route ]] || return 0
    printf 'default via 192.0.2.1 dev test0\n'
}
tc() {
    case $fixture in
        cake) echo 'qdisc cake 8001: root refcnt 2 bandwidth unlimited'; echo 'qdisc clsact ffff: parent ffff:fff1' ;;
        mq-cake) printf 'qdisc mq 0: root\nqdisc cake 1: parent :1 bandwidth unlimited\nqdisc cake 2: parent :2 bandwidth unlimited\n' ;;
        mixed) printf 'qdisc mq 0: root\nqdisc cake 1: parent :1\nqdisc fq_codel 2: parent :2\n' ;;
        fq) echo 'qdisc fq 0: root refcnt 2' ;;
        noqueue) echo 'qdisc noqueue 0: root refcnt 2' ;;
        empty-mq) echo 'qdisc mq 0: root' ;;
        failure) return 1 ;;
    esac
}
check_cake_qdiscs
EOF
for fixture in cake mq-cake; do bash "$SCRATCH/check.sh" "$SCRIPT" "$fixture"; done
echo 'PASS Qdisc checker accepts actual CAKE root and mq with all CAKE leaves'
for fixture in mixed fq noqueue empty-mq no-route failure; do
    if bash "$SCRATCH/check.sh" "$SCRIPT" "$fixture" > "$SCRATCH/check.log" 2>&1; then
        echo "False success: $fixture"; exit 1
    fi
done
echo 'PASS Qdisc checker rejects mixed/non-CAKE/missing/failed inspections'
echo 'CAKE RESULT: 3 groups passed; inspections use fixtures, no host qdisc replacement'
