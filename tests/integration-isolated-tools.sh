#!/usr/bin/env bash
# Real Debian dependency downloads. Run only in a disposable Debian 12/13
# container with apt-get, dpkg-deb, CA certificates and Debian keyring present.
# Example: VPS_TUNE_DOWNLOAD_TEST=1 bash tests/integration-isolated-tools.sh
# Pass the main script path as argument 1. Standard http_proxy/https_proxy are
# honored by APT. This does not alter sysctls, networking or installed packages.
# shellcheck disable=SC2034
set -Eeuo pipefail

if [[ ${VPS_TUNE_DOWNLOAD_TEST:-0} != 1 || ! -f /.dockerenv ]]; then
    printf 'SKIP: set VPS_TUNE_DOWNLOAD_TEST=1 inside a disposable Docker container.\n'
    exit 0
fi
if ((EUID != 0)); then
    printf 'This integration test requires root inside the disposable container.\n' >&2
    exit 1
fi

TEST_SCRIPT=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/vps-tune.sh}
# shellcheck source=/dev/null
source "$TEST_SCRIPT"
trap - EXIT ERR INT TERM
TEST_ROOT=$(mktemp -d /tmp/vps-isolated-integration.XXXXXXXX)
TMP=$TEST_ROOT
CANARY_CONFIG=/etc/apt/apt.conf.d/99-vps-isolated-integration-$$
[[ ! -e $CANARY_CONFIG && ! -L $CANARY_CONFIG ]] || exit 1

finish_test() {
    local status=$?
    trap - EXIT
    rm -f -- "$CANARY_CONFIG"
    if ((status)); then
        printf 'Integration test failed; recent build diagnostics:\n' >&2
        tail -n 30 "$TEST_ROOT"/*.log >&2 || true
    fi
    if [[ ${VPS_TUNE_KEEP_DOWNLOAD_TEST:-0} == 1 ]]; then
        printf 'Preserved test artifacts: %s\n' "$TEST_ROOT"
    else
        rm -rf -- "$TEST_ROOT"
    fi
    exit "$status"
}
trap finish_test EXIT

fingerprint_host_package_state() {
    local directory
    {
        for directory in /etc/apt /var/lib/apt /var/cache/apt /var/lib/dpkg /var/log/apt; do
            if [[ -e $directory || -L $directory ]]; then
                find "$directory" -printf '%y %m %u %g %p %l\n'
                find "$directory" -type f -exec sha256sum {} +
            else
                printf 'absent %s\n' "$directory"
            fi
        done
    } | LC_ALL=C sort
}

check_wrappers() {
    local bundle=$1 command
    for command in ip tc sysctl modprobe modinfo iperf3 jq timeout getent; do
        [[ -x $bundle/bin/$command ]] || return 1
        case $command in
            ip|tc) "$bundle/bin/$command" -V ;;
            *) "$bundle/bin/$command" --version ;;
        esac
    done
    [[ $(find "$bundle/bin" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 9 ]]
    [[ ! -e $bundle/apt && -s $bundle/packages.tsv ]]
    if grep -F -- "$TEST_ROOT" "$bundle"/bin/*; then
        printf 'Wrapper embeds the temporary build directory.\n' >&2
        return 1
    fi
}

cat > "$CANARY_CONFIG" <<EOF
APT::Update::Pre-Invoke { "touch $TEST_ROOT/host-apt-pre-hook"; };
APT::Update::Post-Invoke { "touch $TEST_ROOT/host-apt-post-hook"; };
DPkg::Pre-Invoke { "touch $TEST_ROOT/host-dpkg-hook"; };
EOF
fingerprint_host_package_state > "$TEST_ROOT/before"

isolated_tools_build "$TEST_ROOT/all-tools" iproute2 procps kmod iperf3 jq coreutils libc-bin > "$TEST_ROOT/all-tools.log" 2>&1
check_wrappers "$TEST_ROOT/all-tools" > "$TEST_ROOT/versions-before.log" 2>&1
mv -- "$TEST_ROOT/all-tools" "$TEST_ROOT/relocated-tools"
check_wrappers "$TEST_ROOT/relocated-tools" > "$TEST_ROOT/versions-after.log" 2>&1
cmp "$TEST_ROOT/versions-before.log" "$TEST_ROOT/versions-after.log"

# Transitive packages may include many programs. Only requested commands may
# be exposed through bin; a jq-only request must never replace host tools.
isolated_tools_build "$TEST_ROOT/jq-only" jq > "$TEST_ROOT/jq-only.log" 2>&1
[[ $(find "$TEST_ROOT/jq-only/bin" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 1 ]]
[[ -x $TEST_ROOT/jq-only/bin/jq && ! -e $TEST_ROOT/jq-only/bin/ip && ! -e $TEST_ROOT/jq-only/apt ]]
printf '{"ok":true}\n' | "$TEST_ROOT/jq-only/bin/jq" -e '.ok == true' >/dev/null

fingerprint_host_package_state > "$TEST_ROOT/after"
cmp "$TEST_ROOT/before" "$TEST_ROOT/after"
[[ ! -e $TEST_ROOT/host-apt-pre-hook && ! -e $TEST_ROOT/host-apt-post-hook && ! -e $TEST_ROOT/host-dpkg-hook ]]
printf 'PASS: all 9 isolated tools, relocation, requested commands, host APT/dpkg state and hook isolation.\n'
