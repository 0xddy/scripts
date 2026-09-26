#!/usr/bin/env bash
# Verifies official binaries offline, after fetching fixtures. No terms accepted.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Disposable Docker container required'; exit 1; }
SCRIPT=${1:-/src/vps-tune.sh}
FIXTURES=${2:-/tmp/singbox-runtime-fixtures}
[[ -f $FIXTURES/ookla.tgz && -f $FIXTURES/jq ]] || { echo 'Run prepare-runtime-fixtures.sh first'; exit 1; }
SCRATCH=$(mktemp -d)
trap 'rm -rf -- "$SCRATCH"' EXIT
dpkg-query -W > "$SCRATCH/packages.before"
find /root -type f -exec sha256sum {} + | sort > "$SCRATCH/profile.before"
passed=0
pass() { printf 'PASS %s\n' "$*"; passed=$((passed + 1)); }
cat > "$SCRATCH/exercise.sh" <<'EOF'
#!/usr/bin/env bash
source "$1"
fixtures=$2
record=$3
scenario=$4
# Force the private jq fallback even when the test image includes system jq.
# All other commands still resolve using the production PATH.
command() {
    if [[ $* == '-v jq' ]]; then return 1; fi
    builtin command "$@"
}
fetch_https() {
    ensure_tmp
    printf '%s\n' "$TMP" > "$record"
    case $1 in
        *jq-linux-*) cp "$fixtures/jq" "$2" ;;
        *ookla-speedtest-*) cp "$fixtures/ookla.tgz" "$2" ;;
        *) die 'Unexpected fixture URL' ;;
    esac
    [[ $scenario != corrupt ]] || printf 'corrupt' >> "$2"
}
ensure_json_parser
[[ $JQ_BIN == "$TMP/jq" ]]
[[ $("$JQ_BIN" --version) == jq-1.8.1 ]]
prepare_isolated_speedtest
[[ $(stat -c %u "$SPEEDTEST_ROOT$HOME") == 65534 ]]
[[ -c $SPEEDTEST_ROOT/dev/null && -c $SPEEDTEST_ROOT/dev/urandom ]]
[[ -f $SPEEDTEST_ROOT/etc/ssl/certs/ca-certificates.crt ]]
printf 'Runtime version: '
"${SPEEDTEST_CMD[@]}" --version
case $scenario in
    success) : ;;
    failure) die 'Intentional failure after runtime creation' ;;
    interrupt) kill -INT "$$" ;;
esac
EOF
for scenario in success failure corrupt interrupt; do
    rc=0
    bash "$SCRATCH/exercise.sh" "$SCRIPT" "$FIXTURES" "$SCRATCH/temp.path" "$scenario" > "$SCRATCH/$scenario.log" 2>&1 || rc=$?
    if [[ $scenario == success ]]; then
        [[ $rc == 0 ]] || { cat "$SCRATCH/$scenario.log"; exit 1; }
        cat "$SCRATCH/$scenario.log"
    else [[ $rc != 0 ]] || { echo "Unexpected success: $scenario"; exit 1; }; fi
    [[ $scenario != interrupt || $rc == 130 ]]
    [[ ! -e $(cat "$SCRATCH/temp.path") ]]
    if [[ $scenario == corrupt ]]; then grep -q '下载校验失败' "$SCRATCH/$scenario.log"; fi
    pass "Private runtime $scenario: temporary tools/config/devices removed on exit"
done
dpkg-query -W > "$SCRATCH/packages.after"
find /root -type f -exec sha256sum {} + | sort > "$SCRATCH/profile.after"
cmp "$SCRATCH/packages.before" "$SCRATCH/packages.after"
cmp "$SCRATCH/profile.before" "$SCRATCH/profile.after"
pass 'No packages installed and no host user-profile files changed'
printf 'RUNTIME RESULT: %s groups passed; actual Ookla --version only, no measurement/terms acceptance\n' "$passed"
