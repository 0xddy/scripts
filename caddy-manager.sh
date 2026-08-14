#!/usr/bin/env bash
# Interactive Caddy APT + xcaddy plugin manager for Debian-family systems.
# The official package remains managed by APT; the custom binary is selected
# through dpkg-divert and update-alternatives using Caddy's documented layout.
# Existing caddy.service/caddy-api.service mode is preserved. This script does
# not change firewall rules or expose the Admin API.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"
MANIFEST="/etc/caddy/xcaddy-plugins.list"
LAST_SUCCESS_MANIFEST="/etc/caddy/xcaddy-plugins.last-success.list"
BUILD_ROOT="/root/build_tmp"
BUILD_OUTPUT="/root/caddy"
LOCK_FILE="/run/lock/caddy-plugin-manager.lock"

DEFAULT_PLUGINS=(
    "github.com/darkweak/souin/plugins/caddy"
    "github.com/darkweak/storages/simplefs/caddy"
    "github.com/mholt/caddy-ratelimit"
    "github.com/mholt/caddy-l4"
)

PLUGINS=()
MANIFEST_EXISTS=0
BUILD_TMP=""
PREFLIGHT_TMP=""
GO_COMMAND=""
PREFERRED_SERVICE_MODE=""
RECOVERY_MODE=""
TXN_ACTIVE=0
TXN_NEW=""
TXN_PREVIOUS=""
TXN_MODE=""
TXN_ORIGINAL_SELECTION=""
TXN_ORIGINAL_CUSTOM_EXISTED=0
PRE_APT_BACKUP=""
PRE_APT_CAPTURED=0

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
else
    C_RESET=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
    C_BOLD=""
    C_DIM=""
fi

log() { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
    error "$*"
    exit 1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

detect_service_mode() {
    local api_active=0
    local api_enabled=0
    local native_active=0
    local native_enabled=0

    if systemctl is-active --quiet caddy-api.service 2>/dev/null; then
        api_active=1
    fi
    if systemctl is-enabled --quiet caddy-api.service 2>/dev/null; then
        api_enabled=1
    fi
    if systemctl is-active --quiet caddy.service 2>/dev/null; then
        native_active=1
    fi
    if systemctl is-enabled --quiet caddy.service 2>/dev/null; then
        native_enabled=1
    fi

    if (((api_active || api_enabled) && (native_active || native_enabled))); then
        printf 'conflict\n'
    elif ((api_active)); then
        printf 'api\n'
    elif ((native_active)); then
        printf 'caddyfile\n'
    elif ((api_enabled)); then
        printf 'api\n'
    elif ((native_enabled)); then
        printf 'caddyfile\n'
    else
        printf 'none\n'
    fi
}

mode_label() {
    case "$1" in
        api) printf 'API 模式（caddy-api.service）' ;;
        caddyfile) printf 'Caddyfile 模式（caddy.service）' ;;
        conflict) printf '冲突：两个服务同时运行或启用' ;;
        *) printf '未运行' ;;
    esac
}

mask_native_service() {
    systemctl disable --now caddy.service >/dev/null 2>&1 || true
    systemctl mask caddy.service >/dev/null
    systemctl daemon-reload
    local state
    state=$(systemctl is-enabled caddy.service 2>/dev/null || true)
    [[ "$state" == "masked" ]] || die "无法将 caddy.service 设为 masked"
}

unmask_native_service() {
    systemctl unmask caddy.service >/dev/null 2>&1 || true
    systemctl daemon-reload
}

stop_caddy_services() {
    systemctl stop caddy-api.service >/dev/null 2>&1 || true
    systemctl stop caddy.service >/dev/null 2>&1 || true
}

official_diversion_exists() {
    dpkg-divert --list /usr/bin/caddy 2>/dev/null | grep -q '/usr/bin/caddy.default'
}

repair_missing_caddy_entrypoint() {
    [[ -x /usr/bin/caddy ]] && return 0
    [[ -x /usr/bin/caddy.default ]] || return 1

    if update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10 >/dev/null 2>&1 &&
        update-alternatives --set caddy /usr/bin/caddy.default >/dev/null 2>&1 &&
        [[ "$(readlink -f /usr/bin/caddy 2>/dev/null || true)" == "/usr/bin/caddy.default" ]]; then
        return 0
    fi

    # Last-resort recovery for a newly-created diversion whose alternatives
    # registration failed. Only replace an absent path or an existing symlink.
    if [[ ! -e /usr/bin/caddy || -L /usr/bin/caddy ]]; then
        rm -f -- /usr/bin/caddy
        ln -s /usr/bin/caddy.default /usr/bin/caddy
        [[ -x /usr/bin/caddy ]]
        return
    fi
    return 1
}

restart_service_mode() {
    local mode=$1

    case "$mode" in
        api)
            unit_exists caddy-api.service || return 1
            mask_native_service
            systemctl enable --now caddy-api.service
            systemctl is-active --quiet caddy-api.service
            ;;
        caddyfile)
            systemctl disable --now caddy-api.service >/dev/null 2>&1 || true
            unmask_native_service
            systemctl enable --now caddy.service
            systemctl is-active --quiet caddy.service
            ;;
        none)
            return 0
            ;;
        *)
            error "检测到服务冲突，请先手动停止其中一个服务"
            return 1
            ;;
    esac
}

cleanup_build_tmp() {
    if [[ -n "$BUILD_TMP" && -d "$BUILD_TMP" ]]; then
        rm -rf -- "$BUILD_TMP"
    fi
    BUILD_TMP=""
}

cleanup_preflight_tmp() {
    if [[ -n "$PREFLIGHT_TMP" && -d "$PREFLIGHT_TMP" ]]; then
        rm -rf -- "$PREFLIGHT_TMP"
    fi
    PREFLIGHT_TMP=""
}

discard_pre_apt_backup() {
    if [[ -n "$PRE_APT_BACKUP" ]]; then
        rm -f -- "$PRE_APT_BACKUP"
    fi
    PRE_APT_BACKUP=""
    PRE_APT_CAPTURED=0
}

capture_direct_custom_before_apt() {
    ((PRE_APT_CAPTURED == 0)) || return 0
    official_diversion_exists && return 0

    if package_installed caddy; then
        binary_is_package_modified || return 0
    else
        [[ -e /usr/bin/caddy ]] || return 0
    fi
    [[ -x /usr/bin/caddy ]] || die "发现已有 /usr/bin/caddy，但它不可执行"
    [[ ! -e /usr/bin/caddy.custom ]] ||
        die "同时发现直接覆盖版和 /usr/bin/caddy.custom，拒绝猜测应保留哪一个"

    PRE_APT_BACKUP="/root/.caddy-plugin-manager.pre-apt.$$"
    install -m 0755 /usr/bin/caddy "$PRE_APT_BACKUP"
    PRE_APT_CAPTURED=1
    log "检测到直接覆盖的插件版 Caddy，已创建本次操作所需的临时回滚副本"
}

migrate_direct_custom_layout() {
    ((PRE_APT_CAPTURED == 1)) || return 0
    official_diversion_exists && return 0

    log "迁移直接覆盖版到 APT 兼容的 alternatives 布局"
    mv -- /usr/bin/caddy /usr/bin/caddy.custom
    if ! dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy; then
        mv -- /usr/bin/caddy.custom /usr/bin/caddy
        die "无法建立 Caddy 的 dpkg-divert 布局"
    fi
    ln -s /usr/bin/caddy.custom /usr/bin/caddy
    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50
    update-alternatives --set caddy /usr/bin/caddy.custom
}

restore_pre_apt_binary() {
    local mode=$RECOVERY_MODE

    ((PRE_APT_CAPTURED == 1)) || return 0
    [[ -x "$PRE_APT_BACKUP" ]] || {
        warn "临时回滚二进制不存在，无法恢复原插件版"
        return 1
    }

    warn "正在恢复 APT 操作前的插件版 Caddy"
    stop_caddy_services
    if official_diversion_exists; then
        if ! install -m 0755 "$PRE_APT_BACKUP" /usr/bin/caddy.custom; then
            warn "无法将临时回滚二进制恢复到 /usr/bin/caddy.custom"
            return 1
        fi
        if [[ -x /usr/bin/caddy.default ]]; then
            if ! update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10 >/dev/null; then
                warn "无法注册 APT 官方 Caddy alternative"
                return 1
            fi
        fi
        if ! update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null ||
            ! update-alternatives --set caddy /usr/bin/caddy.custom >/dev/null ||
            [[ "$(readlink -f /usr/bin/caddy 2>/dev/null || true)" != "/usr/bin/caddy.custom" ]]; then
            warn "无法将 Caddy alternative 恢复到插件版"
            return 1
        fi
    else
        if ! install -m 0755 "$PRE_APT_BACKUP" /usr/bin/caddy || [[ ! -x /usr/bin/caddy ]]; then
            warn "无法恢复 /usr/bin/caddy"
            return 1
        fi
    fi

    if ! restart_service_mode "$mode"; then
        warn "旧插件版已恢复，但原服务未能自动启动"
        return 1
    fi
    discard_pre_apt_backup
    RECOVERY_MODE=""
}

rollback_binary_transaction() {
    local mode=$TXN_MODE

    ((TXN_ACTIVE == 1)) || return 0

    warn "正在回滚 Caddy 二进制"
    stop_caddy_services
    if [[ -n "$TXN_NEW" ]]; then
        if ! rm -f -- "$TXN_NEW"; then
            warn "无法清理未完成的新二进制：$TXN_NEW"
            return 1
        fi
    fi

    if [[ -f "$TXN_PREVIOUS" ]]; then
        if ! rm -f -- /usr/bin/caddy.custom ||
            ! mv -f -- "$TXN_PREVIOUS" /usr/bin/caddy.custom; then
            warn "无法恢复上一版 /usr/bin/caddy.custom"
            return 1
        fi
    elif ((PRE_APT_CAPTURED == 1)) && [[ -x "$PRE_APT_BACKUP" ]]; then
        if ! rm -f -- /usr/bin/caddy.custom ||
            ! install -m 0755 "$PRE_APT_BACKUP" /usr/bin/caddy.custom; then
            warn "无法从 APT 前的临时副本恢复插件版"
            return 1
        fi
    elif ((TXN_ORIGINAL_CUSTOM_EXISTED == 0)); then
        if ! rm -f -- /usr/bin/caddy.custom; then
            warn "无法移除失败的新插件版"
            return 1
        fi
    fi

    if [[ -x /usr/bin/caddy.default ]] &&
        ! update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10 >/dev/null 2>&1; then
        warn "回滚时无法注册 APT 官方 Caddy alternative"
        return 1
    fi

    if [[ "$TXN_ORIGINAL_SELECTION" == "custom" ]]; then
        [[ -x /usr/bin/caddy.custom ]] || {
            warn "回滚目标 /usr/bin/caddy.custom 不存在"
            return 1
        }
        if ! update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50 >/dev/null 2>&1 ||
            ! update-alternatives --set caddy /usr/bin/caddy.custom >/dev/null 2>&1 ||
            [[ "$(readlink -f /usr/bin/caddy 2>/dev/null || true)" != "/usr/bin/caddy.custom" ]]; then
            warn "回滚时无法选择原插件版 alternative"
            return 1
        fi
    else
        [[ -x /usr/bin/caddy.default ]] || {
            warn "回滚目标 /usr/bin/caddy.default 不存在"
            return 1
        }
        if ! update-alternatives --set caddy /usr/bin/caddy.default >/dev/null 2>&1 ||
            [[ "$(readlink -f /usr/bin/caddy 2>/dev/null || true)" != "/usr/bin/caddy.default" ]]; then
            warn "回滚时无法选择原 APT 官方 alternative"
            return 1
        fi
    fi

    if ! restart_service_mode "$mode"; then
        warn "旧二进制已恢复，但原服务未能自动启动"
        return 1
    fi

    discard_pre_apt_backup

    TXN_ACTIVE=0
    TXN_NEW=""
    TXN_PREVIOUS=""
    TXN_MODE=""
    TXN_ORIGINAL_SELECTION=""
    TXN_ORIGINAL_CUSTOM_EXISTED=0
    RECOVERY_MODE=""
}

on_error() {
    local exit_code=$?
    trap - ERR
    error "第 $1 行执行失败（退出码 $exit_code）：$2"
    exit "$exit_code"
}

on_exit() {
    local exit_code=$?
    trap - EXIT
    set +e

    if ((TXN_ACTIVE == 1)); then
        if ! rollback_binary_transaction; then
            warn "自动回滚未完全成功；临时回滚文件已保留，请人工检查"
        fi
    elif ((PRE_APT_CAPTURED == 1)); then
        if ! restore_pre_apt_binary; then
            warn "自动恢复未完全成功；临时副本保留在：$PRE_APT_BACKUP"
        fi
    elif [[ -n "$RECOVERY_MODE" ]]; then
        warn "安装流程未完成，尝试恢复原服务"
        repair_missing_caddy_entrypoint || true
        restart_service_mode "$RECOVERY_MODE" || true
    fi
    cleanup_build_tmp
    cleanup_preflight_tmp
    if [[ -n "$TXN_NEW" ]]; then
        rm -f -- "$TXN_NEW"
    fi
    exit "$exit_code"
}

on_signal() {
    local signal=$1

    warn "收到 $signal，正在安全退出"
    case "$signal" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
    esac
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

((EUID == 0)) || die "请以 root 运行：sudo bash ${0##*/}"
[[ -t 0 ]] || die "这是交互式脚本，请直接在终端中运行"
command -v systemctl >/dev/null 2>&1 || die "该脚本需要 systemd"
command -v flock >/dev/null 2>&1 ||
    die "缺少 flock，请先执行：apt-get install -y util-linux"

install -d -m 0755 /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die "已有另一个 caddy-plugin-manager 实例正在运行"

if [[ ! -r /etc/os-release ]]; then
    die "无法识别操作系统"
fi

# shellcheck disable=SC1091
source /etc/os-release
OS_FAMILY="${ID:-} ${ID_LIKE:-}"
if [[ " $OS_FAMILY " != *" debian "* && "${ID:-}" != "ubuntu" && "${ID:-}" != "raspbian" ]]; then
    die "仅支持 Debian、Ubuntu、Raspbian 及 Debian 系衍生版"
fi

export DEBIAN_FRONTEND=noninteractive

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause_menu() {
    printf '\n'
    read -r -p "按 Enter 返回主菜单..." _ || true
}

clear_screen() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[2J\033[H'
    fi
}

plugin_path() {
    local value=$1
    value=${value%%=*}
    value=${value%%@*}
    printf '%s\n' "$value"
}

valid_plugin_spec() {
    # Production-safe form: Go package path with optional @version.
    [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._~+-]+)+(@[A-Za-z0-9._~+/-]+)?$ ]]
}

upsert_plugin() {
    local spec=$1
    local wanted_path
    local existing
    local -a updated=()

    wanted_path=$(plugin_path "$spec")
    for existing in "${PLUGINS[@]}"; do
        if [[ "$(plugin_path "$existing")" != "$wanted_path" ]]; then
            updated+=("$existing")
        fi
    done
    updated+=("$spec")
    PLUGINS=("${updated[@]}")
}

load_manifest() {
    local line
    PLUGINS=()
    MANIFEST_EXISTS=0

    if [[ ! -f "$MANIFEST" ]]; then
        PLUGINS=("${DEFAULT_PLUGINS[@]}")
        return
    fi

    MANIFEST_EXISTS=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if valid_plugin_spec "$line"; then
            upsert_plugin "$line"
        else
            warn "忽略插件清单中的无效行：$line"
        fi
    done <"$MANIFEST"
}

save_manifest() {
    local tmp
    local spec

    install -d -m 0755 /etc/caddy
    tmp=$(mktemp /etc/caddy/.xcaddy-plugins.XXXXXX)
    {
        printf '# Managed by caddy-plugin-manager.sh\n'
        printf '# One Go package[@version] per line. An empty list is allowed.\n'
        for spec in "${PLUGINS[@]}"; do
            printf '%s\n' "$spec"
        done
    } >"$tmp"
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$MANIFEST"
    MANIFEST_EXISTS=1
}

initialize_manifest() {
    load_manifest
    if ((MANIFEST_EXISTS == 0)); then
        save_manifest
        log "已创建默认插件清单：$MANIFEST"
    fi
}

print_configured_plugins() {
    local index=1
    local spec

    if ((${#PLUGINS[@]} == 0)); then
        printf '  （空清单：将构建不带第三方插件的 Caddy）\n'
        return
    fi
    for spec in "${PLUGINS[@]}"; do
        printf '  %2d. %s\n' "$index" "$spec"
        ((index += 1))
    done
}

apt_version() {
    if package_installed caddy; then
        dpkg-query -W -f='${Version}' caddy
    else
        printf '未安装'
    fi
}

current_caddy_version() {
    if [[ -x /usr/bin/caddy ]]; then
        /usr/bin/caddy version 2>/dev/null | awk 'NR == 1 {print $1}' || true
    else
        printf '不可用'
    fi
}

apt_core_version_quiet() {
    local package_version
    local core_version

    package_installed caddy || return 1
    package_version=$(dpkg-query -W -f='${Version}' caddy 2>/dev/null) || return 1
    core_version=${package_version#*:}
    core_version=${core_version%%-*}
    [[ "$core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~].*)?$ ]] || return 1
    printf 'v%s\n' "$core_version"
}

current_binary_path() {
    if [[ -e /usr/bin/caddy ]]; then
        readlink -f /usr/bin/caddy 2>/dev/null || printf '/usr/bin/caddy'
    else
        printf '不存在'
    fi
}

manifest_matches_last_success() {
    local current_plugins
    local successful_plugins

    [[ -f "$LAST_SUCCESS_MANIFEST" ]] || return 1
    current_plugins=$(printf '%s\n' "${PLUGINS[@]}")
    successful_plugins=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        "$LAST_SUCCESS_MANIFEST")
    [[ "$current_plugins" == "$successful_plugins" ]]
}

manifest_application_state() {
    local binary_path
    local apt_core=""
    local current_core=""
    local manifest_synced=0
    local core_synced=1

    binary_path=$(current_binary_path)
    case "$binary_path" in
        /usr/bin/caddy.custom)
            apt_core=$(apt_core_version_quiet || true)
            current_core=$(current_caddy_version)
            if [[ -n "$apt_core" && "$current_core" == v* && "$apt_core" != "$current_core" ]]; then
                core_synced=0
            fi
            if manifest_matches_last_success; then
                manifest_synced=1
            fi

            if ((core_synced == 1 && manifest_synced == 1)); then
                printf '插件版与清单一致'
            elif ((core_synced == 0 && manifest_synced == 0)); then
                printf '需要重建（APT 核心和插件清单均有变化）'
            elif ((core_synced == 0)); then
                printf '需要重建（APT 核心 %s，当前 %s）' "$apt_core" "$current_core"
            else
                printf '插件清单有待应用的修改'
            fi
            ;;
        /usr/bin/caddy.default)
            printf '当前使用 APT 官方版'
            ;;
        /usr/bin/caddy)
            if ! package_installed caddy; then
                printf '检测到未受 APT 管理的手工安装版；安装时会安全迁移'
            elif binary_is_package_modified; then
                printf '检测到直接覆盖的自定义版；下次构建会安全迁移'
            else
                printf '当前使用 APT 官方版'
            fi
            ;;
        *)
            printf '无法判断'
            ;;
    esac
}

print_status() {
    local mode
    local mode_color=$C_GREEN
    local manifest_state
    local guard_state="未启用"

    load_manifest
    mode=$(detect_service_mode)
    [[ "$mode" == "conflict" ]] && mode_color=$C_RED
    [[ "$mode" == "none" ]] && mode_color=$C_YELLOW

    if ((MANIFEST_EXISTS == 1)); then
        manifest_state="$MANIFEST"
    else
        manifest_state="尚未创建；首次安装将写入四个默认插件"
    fi

    if [[ "$(systemctl is-enabled caddy.service 2>/dev/null || true)" == "masked" ]]; then
        guard_state="caddy.service 已 masked"
    fi

    printf '%s┌──────────────────────────────────────────────────────────────┐%s\n' "$C_CYAN" "$C_RESET"
    printf '%s│%s %sCaddy APT + xcaddy 插件管理器%s                         %sv%s%s│%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$SCRIPT_VERSION" "$C_CYAN" "$C_RESET"
    printf '%s├──────────────────────────────────────────────────────────────┤%s\n' "$C_CYAN" "$C_RESET"
    printf '  系统             %s\n' "${PRETTY_NAME:-unknown}"
    printf '  APT Caddy        %s\n' "$(apt_version)"
    printf '  当前 Caddy       %s\n' "$(current_caddy_version)"
    printf '  生效二进制       %s\n' "$(current_binary_path)"
    printf '  服务模式         %s%s%s\n' "$mode_color" "$(mode_label "$mode")" "$C_RESET"
    printf '  APT 服务保护     %s\n' "$guard_state"
    printf '  插件清单         %s\n' "$manifest_state"
    printf '  配置插件数量     %d\n' "${#PLUGINS[@]}"
    printf '  应用状态         %s\n' "$(manifest_application_state)"
    printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$C_CYAN" "$C_RESET"
}

print_menu() {
    printf '\n%s安装与构建%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s[1]%s 一键安装/更新     APT 强制重装 Caddy，再按清单构建替换\n' "$C_CYAN" "$C_RESET"
    printf '  %s[2]%s 重新构建并应用    不升级 APT，仅按当前清单重新编译\n' "$C_CYAN" "$C_RESET"
    printf '\n%s插件清单%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s[3]%s 新增/更新插件     支持 Go 包路径及 @版本\n' "$C_CYAN" "$C_RESET"
    printf '  %s[4]%s 删除插件          按编号删除，可删除默认插件\n' "$C_CYAN" "$C_RESET"
    printf '  %s[5]%s 查看插件          对比配置清单和当前编译模块\n' "$C_CYAN" "$C_RESET"
    printf '  %s[6]%s 恢复默认插件      重置为 Souin、SimpleFS、限流和 L4\n' "$C_CYAN" "$C_RESET"
    printf '\n%s二进制管理%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s[7]%s 切回官方版本      选择 APT 原版二进制，不删除插件清单\n' "$C_CYAN" "$C_RESET"
    printf '\n  %s[0]%s 退出\n' "$C_DIM" "$C_RESET"
}

install_apt_prerequisites() {
    log "安装 APT 和构建基础依赖"
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        debian-archive-keyring \
        debian-keyring \
        gnupg \
        python3-minimal \
        tar \
        util-linux
}

configure_official_repositories() {
    log "配置 Caddy 官方稳定版 APT 仓库"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
        gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-stable.list
    chmod 0644 \
        /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        /etc/apt/sources.list.d/caddy-stable.list

    log "配置 xcaddy 官方 APT 仓库"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' |
        gpg --dearmor --yes -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-xcaddy.list
    chmod 0644 \
        /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg \
        /etc/apt/sources.list.d/caddy-xcaddy.list
    apt-get update
}

prepare_for_apt_transaction() {
    PREFERRED_SERVICE_MODE=$(detect_service_mode)
    if [[ "$PREFERRED_SERVICE_MODE" == "conflict" ]]; then
        die "caddy.service 与 caddy-api.service 同时运行或启用，请先解决服务冲突"
    fi

    RECOVERY_MODE=$PREFERRED_SERVICE_MODE
    capture_direct_custom_before_apt
    if [[ "$PREFERRED_SERVICE_MODE" == "api" ]]; then
        systemctl stop caddy-api.service >/dev/null 2>&1 || true
        mask_native_service
    elif [[ "$PREFERRED_SERVICE_MODE" == "caddyfile" ]]; then
        systemctl stop caddy.service >/dev/null 2>&1 || true
        unmask_native_service
    fi
    migrate_direct_custom_layout
}

install_apt_stack() {
    prepare_for_apt_transaction
    install_apt_prerequisites
    configure_official_repositories

    log "通过 APT 强制重新安装 Caddy，并安装或升级 xcaddy 和 Go"
    apt-get install --reinstall -y caddy
    apt-get install -y xcaddy golang-go

    if official_diversion_exists && [[ -x /usr/bin/caddy.default ]]; then
        update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
    fi

    if [[ "$PREFERRED_SERVICE_MODE" == "api" ]]; then
        mask_native_service
        restart_service_mode api || die "APT 完成后无法恢复 caddy-api.service"
    elif [[ "$PREFERRED_SERVICE_MODE" == "caddyfile" ]]; then
        restart_service_mode caddyfile || die "APT 完成后无法恢复 caddy.service"
    elif [[ "$PREFERRED_SERVICE_MODE" == "none" ]]; then
        PREFERRED_SERVICE_MODE=$(detect_service_mode)
        [[ "$PREFERRED_SERVICE_MODE" == "conflict" ]] &&
            die "APT 安装后检测到两个 Caddy 服务同时运行或启用"
        RECOVERY_MODE=$PREFERRED_SERVICE_MODE
    fi
}

ensure_build_tools() {
    if command -v xcaddy >/dev/null 2>&1 && command -v go >/dev/null 2>&1 &&
        command -v python3 >/dev/null 2>&1; then
        return
    fi

    install_apt_prerequisites
    configure_official_repositories
    apt-get install -y xcaddy golang-go
}

version_at_least() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

install_isolated_go_toolchain() {
    local arch
    local metadata_dir
    local metadata
    local version
    local filename
    local checksum
    local archive
    local destination
    local extract_dir

    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        armv7l | armv6l) arch="armv6l" ;;
        i386 | i686) arch="386" ;;
        riscv64 | s390x | ppc64le) arch=$(uname -m) ;;
        *) die "不支持自动安装 Go 的架构：$(uname -m)" ;;
    esac

    install -d -m 0755 "$BUILD_ROOT" /opt/caddy-plugin-manager
    metadata_dir=$(mktemp -d "$BUILD_ROOT/go-bootstrap.XXXXXX")
    BUILD_TMP=$metadata_dir
    metadata="$metadata_dir/releases.json"
    curl -fsSL 'https://go.dev/dl/?mode=json' -o "$metadata"

    IFS=$'\t' read -r version filename checksum < <(
        python3 - "$metadata" "$arch" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)

arch = sys.argv[2]
for release in releases:
    if not release.get("stable"):
        continue
    for item in release.get("files", []):
        if item.get("os") == "linux" and item.get("arch") == arch and item.get("kind") == "archive":
            print("\t".join((release["version"], item["filename"], item["sha256"])))
            raise SystemExit(0)

raise SystemExit("No matching stable Go toolchain found")
PY
    )

    [[ -n "$version" && -n "$filename" && -n "$checksum" ]] ||
        die "无法解析 Go 官方工具链信息"
    [[ "$version" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "Go 官方元数据中的版本格式异常：$version"
    [[ "$filename" == "$version.linux.$arch.tar.gz" ]] ||
        die "Go 官方元数据中的文件名异常：$filename"
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] ||
        die "Go 官方元数据中的 SHA256 格式异常"
    destination="/opt/caddy-plugin-manager/$version"

    if [[ ! -x "$destination/bin/go" ]]; then
        if [[ -e "$destination" ]]; then
            rm -rf -- "$destination"
        fi
        log "APT Go 过旧，安装隔离的官方 $version 工具链"
        archive="$metadata_dir/$filename"
        curl -fL "https://go.dev/dl/$filename" -o "$archive"
        (
            cd "$metadata_dir"
            printf '%s  %s\n' "$checksum" "$filename" | sha256sum -c -
        )
        extract_dir="$metadata_dir/extract"
        install -d -m 0755 "$extract_dir"
        tar -xzf "$archive" -C "$extract_dir"
        [[ -x "$extract_dir/go/bin/go" ]] || die "Go 工具链解压结果无效"
        mv -- "$extract_dir/go" "$destination"
    fi

    GO_COMMAND="$destination/bin/go"
    cleanup_build_tmp
}

select_go_toolchain() {
    local go_version=""

    if command -v go >/dev/null 2>&1; then
        go_version=$(go env GOVERSION 2>/dev/null | sed 's/^go//' || true)
    fi

    if [[ -n "$go_version" ]] && version_at_least 1.21 "$go_version"; then
        GO_COMMAND=$(command -v go)
    else
        install_isolated_go_toolchain
    fi

    log "使用 Go：$($GO_COMMAND version)"
}

caddy_core_version() {
    local package_version
    local core_version

    package_installed caddy || die "请先使用菜单 1 通过 APT 安装 Caddy"
    package_version=$(dpkg-query -W -f='${Version}' caddy)
    core_version=${package_version#*:}
    core_version=${core_version%%-*}
    [[ "$core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~].*)?$ ]] ||
        die "无法解析 APT Caddy 版本：$package_version"
    printf 'v%s\n' "$core_version"
}

build_custom_caddy() {
    local core_version
    local candidate_version
    local plugin
    local inventory_file
    local -a args=()
    local -a plugin_packages=()

    load_manifest
    ensure_build_tools
    select_go_toolchain
    core_version=$(caddy_core_version)

    cleanup_build_tmp
    install -d -m 0755 "$BUILD_ROOT"
    BUILD_TMP=$(mktemp -d "$BUILD_ROOT/xcaddy.XXXXXX")
    rm -f -- "$BUILD_OUTPUT"

    args=(build "$core_version" --output "$BUILD_OUTPUT")
    for plugin in "${PLUGINS[@]}"; do
        args+=(--with "$plugin")
    done

    log "构建 $core_version：${#PLUGINS[@]} 个第三方插件"
    TMPDIR="$BUILD_TMP" \
        GOTOOLCHAIN=auto \
        XCADDY_WHICH_GO="$GO_COMMAND" \
        xcaddy "${args[@]}"

    [[ -x "$BUILD_OUTPUT" ]] || die "xcaddy 没有生成 $BUILD_OUTPUT"
    candidate_version=$("$BUILD_OUTPUT" version | awk 'NR == 1 {print $1}')
    [[ "$candidate_version" == "$core_version" ]] ||
        die "插件依赖改变了 Caddy 核心版本：期望 $core_version，实际 $candidate_version"

    inventory_file="$BUILD_TMP/modules.json"
    "$BUILD_OUTPUT" list-modules --json --packages --versions --skip-standard >"$inventory_file"
    for plugin in "${PLUGINS[@]}"; do
        plugin_packages+=("$(plugin_path "$plugin")")
    done
    if ! python3 - "$inventory_file" "${plugin_packages[@]}" <<'PY'; then
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    modules = json.load(handle)

packages = {
    item.get("package_url", "").strip()
    for item in modules
    if isinstance(item, dict) and item.get("package_url")
}
missing = []
for wanted in sys.argv[2:]:
    matched = any(
        package == wanted
        or package.startswith(wanted + "/")
        or wanted.startswith(package + "/")
        for package in packages
    )
    if not matched:
        missing.append(wanted)

if missing:
    print("未在候选二进制中发现这些插件模块：", file=sys.stderr)
    for package in missing:
        print(f"  - {package}", file=sys.stderr)
    raise SystemExit(1)
PY
        die "候选二进制的插件清单验证失败"
    fi
    cleanup_build_tmp
    log "构建验证通过：$BUILD_OUTPUT（$candidate_version）"
}

service_user_and_home() {
    local unit=$1
    local service_user
    local service_home

    service_user=$(systemctl show "$unit" --property=User --value 2>/dev/null || true)
    service_user=${service_user:-root}
    service_home=$(getent passwd "$service_user" 2>/dev/null | awk -F: 'NR == 1 {print $6}')
    if [[ -z "$service_home" ]]; then
        service_user=root
        service_home=/root
    fi
    printf '%s\t%s\n' "$service_user" "$service_home"
}

validate_candidate_config() {
    local mode=$1
    local candidate_source=${2:-$BUILD_OUTPUT}
    local unit
    local service_user
    local service_home
    local working_directory
    local config=""
    local adapter=""
    local candidate
    local discovered=""
    local exec_start=""
    local -a validate_args=()

    case "$mode" in
        caddyfile)
            unit=caddy.service
            config=/etc/caddy/Caddyfile
            adapter=caddyfile
            ;;
        api)
            unit=caddy-api.service
            exec_start=$(systemctl show "$unit" --property=ExecStart --value 2>/dev/null || true)
            [[ "$exec_start" == *"--resume"* ]] ||
                die "$unit 未使用 --resume，重启可能丢失 API 配置，拒绝替换"
            ;;
        none)
            warn "当前没有启用的 Caddy 服务，跳过运行配置预检"
            return 0
            ;;
        *)
            die "未知服务模式，无法预检：$mode"
            ;;
    esac

    IFS=$'\t' read -r service_user service_home < <(service_user_and_home "$unit")
    working_directory=$(systemctl show "$unit" --property=WorkingDirectory --value 2>/dev/null || true)
    if [[ -z "$working_directory" || ! -d "$working_directory" ]]; then
        working_directory=/
    fi
    if [[ "$mode" == "api" ]]; then
        config="$service_home/.config/caddy/autosave.json"
        if [[ ! -f "$config" && -d "$service_home" ]]; then
            discovered=$(find "$service_home" -type f -name autosave.json \
                -path '*/caddy/autosave.json' -print -quit 2>/dev/null || true)
            config=$discovered
        fi
    fi

    [[ -n "$config" && -f "$config" ]] ||
        die "未找到当前 $unit 的持久配置文件，拒绝重启以免空配置运行"

    [[ -x "$candidate_source" ]] || die "候选二进制不可执行：$candidate_source"
    cleanup_preflight_tmp
    PREFLIGHT_TMP=$(mktemp -d /var/tmp/caddy-preflight.XXXXXX)
    chmod 0755 "$PREFLIGHT_TMP"
    candidate="$PREFLIGHT_TMP/caddy"
    install -m 0755 "$candidate_source" "$candidate"
    validate_args=(validate --config "$config")
    if [[ -n "$adapter" ]]; then
        validate_args+=(--adapter "$adapter")
    fi

    log "使用候选二进制预检当前配置：$config"
    if [[ "$service_user" != "root" && -x "$(command -v runuser 2>/dev/null || true)" ]]; then
        if ! runuser -u "$service_user" -- bash -c \
            'cd -- "$1" && shift && exec "$@"' bash "$working_directory" \
            env \
            HOME="$service_home" \
            XDG_CONFIG_HOME="$service_home/.config" \
            XDG_DATA_HOME="$service_home/.local/share" \
            "$candidate" "${validate_args[@]}"; then
            cleanup_preflight_tmp
            die "候选二进制无法加载当前配置，已取消替换"
        fi
    else
        if [[ "$service_user" != "root" ]]; then
            warn "runuser 不可用，改用 root 身份执行配置预检"
        fi
        if ! (
            cd -- "$working_directory"
            env \
                HOME="$service_home" \
                XDG_CONFIG_HOME="$service_home/.config" \
                XDG_DATA_HOME="$service_home/.local/share" \
                "$candidate" "${validate_args[@]}"
        ); then
            cleanup_preflight_tmp
            die "候选二进制无法加载当前配置，已取消替换"
        fi
    fi
    cleanup_preflight_tmp
}

record_successful_manifest() {
    local tmp
    local plugin

    [[ -f "$MANIFEST" ]] || return 1
    tmp=$(mktemp /etc/caddy/.xcaddy-plugins.last-success.XXXXXX) || return 1
    if ! {
        printf '# Last successfully applied by caddy-plugin-manager.sh\n'
        for plugin in "${PLUGINS[@]}"; do
            printf '%s\n' "$plugin"
        done
    } >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$LAST_SUCCESS_MANIFEST"; then
        rm -f -- "$tmp"
        return 1
    fi
}

binary_is_package_modified() {
    local verification

    verification=$(dpkg -V caddy 2>/dev/null || true)
    grep -qE '[[:space:]]/usr/bin/caddy$' <<<"$verification"
}

ensure_official_binary_layout() {
    local mode=$1

    if official_diversion_exists; then
        if [[ ! -x /usr/bin/caddy.default ]]; then
            [[ "$mode" == "api" ]] && mask_native_service
            apt-get install --reinstall -y caddy
            stop_caddy_services
        fi
        [[ -x /usr/bin/caddy.default ]] ||
            die "无法恢复 /usr/bin/caddy.default"
        update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
        return
    fi

    if binary_is_package_modified; then
        log "检测到 /usr/bin/caddy 曾被直接覆盖，先恢复 APT 原版"
        [[ "$mode" == "api" ]] && mask_native_service
        apt-get install --reinstall -y caddy
        stop_caddy_services
    fi

    dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy
    [[ -x /usr/bin/caddy.default ]] ||
        die "dpkg-divert 后缺少 APT 原版二进制"
    ln -s /usr/bin/caddy.default /usr/bin/caddy
    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
    update-alternatives --set caddy /usr/bin/caddy.default
}

apply_custom_binary() {
    local requested_mode=${1:-}
    local mode
    local original_binary
    local original_selection="default"
    local new_binary="/usr/bin/caddy.custom.new.$$"

    [[ -x "$BUILD_OUTPUT" ]] || die "请先构建 $BUILD_OUTPUT"
    mode=${requested_mode:-$(detect_service_mode)}
    [[ "$mode" != "conflict" ]] ||
        die "两个 Caddy 服务同时运行或启用，拒绝替换二进制"
    validate_candidate_config "$mode"

    original_binary=$(current_binary_path)
    RECOVERY_MODE=$mode
    capture_direct_custom_before_apt
    if [[ "$original_binary" == "/usr/bin/caddy.custom" ]] || ((PRE_APT_CAPTURED == 1)); then
        original_selection="custom"
    fi
    stop_caddy_services
    migrate_direct_custom_layout
    ensure_official_binary_layout "$mode"

    rm -f -- "$new_binary"
    TXN_NEW=$new_binary
    install -m 0755 "$BUILD_OUTPUT" "$new_binary"

    TXN_MODE=$mode
    TXN_PREVIOUS="/usr/bin/caddy.custom.rollback.$$"
    TXN_ORIGINAL_SELECTION=$original_selection
    TXN_ORIGINAL_CUSTOM_EXISTED=0
    if [[ -e /usr/bin/caddy.custom ]] || ((PRE_APT_CAPTURED == 1)); then
        TXN_ORIGINAL_CUSTOM_EXISTED=1
    fi
    rm -f -- "$TXN_PREVIOUS"
    TXN_ACTIVE=1

    if [[ -e /usr/bin/caddy.custom ]]; then
        mv -- /usr/bin/caddy.custom "$TXN_PREVIOUS"
    fi
    mv -- "$new_binary" /usr/bin/caddy.custom
    TXN_NEW=""

    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
    update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50
    update-alternatives --set caddy /usr/bin/caddy.custom

    [[ "$(readlink -f /usr/bin/caddy)" == "/usr/bin/caddy.custom" ]] ||
        die "/usr/bin/caddy 没有切换到插件版"
    /usr/bin/caddy list-modules >/dev/null

    if ! restart_service_mode "$mode"; then
        journalctl -u caddy.service -u caddy-api.service -n 100 --no-pager >&2 || true
        if rollback_binary_transaction; then
            die "新插件版启动失败，已恢复原二进制"
        fi
        die "新插件版启动失败，自动回滚也未完成；回滚文件已保留"
    fi
    if ! record_successful_manifest; then
        warn "二进制已经生效，但未能写入成功清单记录：$LAST_SUCCESS_MANIFEST"
    fi
    discard_pre_apt_backup

    rm -f -- "$TXN_PREVIOUS"
    TXN_ACTIVE=0
    TXN_PREVIOUS=""
    TXN_MODE=""
    TXN_ORIGINAL_SELECTION=""
    TXN_ORIGINAL_CUSTOM_EXISTED=0
    RECOVERY_MODE=""
    log "插件版已生效：/usr/bin/caddy.custom"
}

build_and_apply() {
    local mode=${1:-}
    build_custom_caddy
    apply_custom_binary "$mode"
}

one_click_install() {
    if ! confirm "将通过 APT 强制重装/升级 Caddy，并按插件清单重新构建，确认继续？"; then
        warn "已取消"
        return
    fi

    initialize_manifest
    install_apt_stack
    build_and_apply "$PREFERRED_SERVICE_MODE"
    log "一键安装/更新完成"
}

maybe_rebuild_now() {
    if ! package_installed caddy; then
        warn "插件清单已保存；请使用菜单 1 完成首次安装"
        return
    fi

    if confirm "是否立即重新构建并应用？"; then
        build_and_apply
    else
        log "插件清单已保存，尚未应用到当前二进制"
    fi
}

add_plugins() {
    local input
    local changed=0

    load_manifest
    cat <<'EOF'

逐行输入需要新增或更新的插件，直接按 Enter 结束。
支持：
  github.com/caddy-dns/cloudflare
  github.com/caddy-dns/cloudflare@v0.2.1
EOF

    while :; do
        read -r -p "插件: " input
        [[ -n "$input" ]] || break
        if ! valid_plugin_spec "$input"; then
            warn "格式无效：请输入 Go 包路径，可附加 @版本，不能包含空格"
            continue
        fi
        upsert_plugin "$input"
        changed=1
        log "已加入：$input"
    done

    if ((changed == 0)); then
        warn "没有修改插件清单"
        return
    fi

    save_manifest
    maybe_rebuild_now
}

remove_plugins() {
    local input
    local token
    local index
    local spec
    local -A remove_indexes=()
    local -a kept=()
    local -a tokens=()

    load_manifest
    if ((${#PLUGINS[@]} == 0)); then
        warn "插件清单已经为空"
        return
    fi

    printf '\n当前插件：\n'
    print_configured_plugins
    printf '\n输入编号，可用逗号分隔；输入 all 删除全部。\n'
    read -r -p "删除: " input
    input=${input//[[:space:]]/}
    [[ -n "$input" ]] || {
        warn "已取消"
        return
    }

    if [[ "$input" == "all" ]]; then
        for ((index = 1; index <= ${#PLUGINS[@]}; index++)); do
            remove_indexes["$index"]=1
        done
    else
        IFS=',' read -r -a tokens <<<"$input"
        for token in "${tokens[@]}"; do
            [[ "$token" =~ ^[0-9]+$ ]] || {
                warn "无效编号：$token"
                continue
            }
            index=$((10#$token))
            if ((index < 1 || index > ${#PLUGINS[@]})); then
                warn "编号超出范围：$token"
                continue
            fi
            remove_indexes["$index"]=1
        done
    fi

    if ((${#remove_indexes[@]} == 0)); then
        warn "没有有效的删除项"
        return
    fi

    printf '\n将删除：\n'
    for ((index = 1; index <= ${#PLUGINS[@]}; index++)); do
        if [[ -n "${remove_indexes[$index]:-}" ]]; then
            printf '  - %s\n' "${PLUGINS[$((index - 1))]}"
        fi
    done
    if ! confirm "确认删除？"; then
        warn "已取消"
        return
    fi

    for ((index = 1; index <= ${#PLUGINS[@]}; index++)); do
        spec=${PLUGINS[$((index - 1))]}
        if [[ -z "${remove_indexes[$index]:-}" ]]; then
            kept+=("$spec")
        fi
    done
    PLUGINS=("${kept[@]}")
    save_manifest
    maybe_rebuild_now
}

show_plugins() {
    load_manifest
    printf '\n配置清单：%s\n' "$MANIFEST"
    print_configured_plugins
    if [[ -f "$LAST_SUCCESS_MANIFEST" ]]; then
        printf '\n最后成功应用的清单：%s\n' "$LAST_SUCCESS_MANIFEST"
    fi

    printf '\n当前二进制中的非标准模块：\n'
    if [[ -x /usr/bin/caddy ]]; then
        /usr/bin/caddy list-modules --packages --versions --skip-standard || true
    else
        printf '  Caddy 尚未安装。\n'
    fi
}

restore_default_plugins() {
    if ! confirm "将插件清单重置为四个默认插件，确认继续？"; then
        warn "已取消"
        return
    fi

    PLUGINS=("${DEFAULT_PLUGINS[@]}")
    save_manifest
    log "已恢复默认插件清单"
    maybe_rebuild_now
}

rebuild_only() {
    package_installed caddy || {
        warn "Caddy 尚未通过 APT 安装，请使用菜单 1"
        return
    }
    if ! confirm "将按当前插件清单重新构建并替换，确认继续？"; then
        warn "已取消"
        return
    fi

    initialize_manifest
    build_and_apply
}

restore_official_binary() {
    local mode

    if [[ "$(current_binary_path)" == "/usr/bin/caddy.default" ]]; then
        log "当前已经是 APT 官方二进制"
        return
    fi

    if [[ ! -x /usr/bin/caddy.default ]]; then
        if ! package_installed caddy; then
            warn "Caddy APT 软件包尚未安装"
            return
        fi
        if ! binary_is_package_modified; then
            log "当前已经是 APT 官方二进制"
            return
        fi

        if ! confirm "将通过 APT 恢复官方二进制；若现有配置依赖插件会自动回滚，确认继续？"; then
            warn "已取消"
            return
        fi

        mode=$(detect_service_mode)
        [[ "$mode" != "conflict" ]] || {
            warn "两个服务同时运行或同时启用，请先解决冲突"
            return
        }

        prepare_for_apt_transaction
        log "通过 APT 恢复官方 Caddy 二进制"
        apt-get install --reinstall -y caddy
        [[ -x /usr/bin/caddy.default ]] || die "APT 未能恢复 /usr/bin/caddy.default"
        update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10
        validate_candidate_config "$mode" /usr/bin/caddy.default
        stop_caddy_services
        update-alternatives --set caddy /usr/bin/caddy.default
        if ! restart_service_mode "$mode"; then
            if ! restore_pre_apt_binary; then
                journalctl -u caddy.service -u caddy-api.service -n 100 --no-pager >&2 || true
                die "官方版与原插件版均未能启动，请检查上方日志"
            fi
            warn "官方二进制无法加载现有配置，已恢复原插件版"
            return
        fi

        discard_pre_apt_backup
        RECOVERY_MODE=""
        log "已恢复 APT 官方二进制：/usr/bin/caddy.default"
        return
    fi

    if ! confirm "切回 APT 官方二进制可能导致依赖插件的配置无法启动，确认继续？"; then
        warn "已取消"
        return
    fi

    mode=$(detect_service_mode)
    [[ "$mode" != "conflict" ]] || {
        warn "两个服务同时运行或同时启用，请先解决冲突"
        return
    }

    validate_candidate_config "$mode" /usr/bin/caddy.default
    RECOVERY_MODE=$mode
    stop_caddy_services
    update-alternatives --set caddy /usr/bin/caddy.default
    if ! restart_service_mode "$mode"; then
        warn "官方二进制无法加载现有配置，恢复插件版"
        if [[ -x /usr/bin/caddy.custom ]] &&
            update-alternatives --set caddy /usr/bin/caddy.custom &&
            restart_service_mode "$mode"; then
            RECOVERY_MODE=""
            warn "已恢复原插件版"
            return
        fi
        journalctl -u caddy.service -u caddy-api.service -n 100 --no-pager >&2 || true
        die "官方版与原插件版均未能启动，请检查上方日志"
    fi

    RECOVERY_MODE=""
    log "已切换到 /usr/bin/caddy.default"
}

main_menu() {
    local choice

    while :; do
        clear_screen
        print_status
        print_menu
        printf '\n%s请输入菜单编号 [0-7]：%s' "$C_BOLD" "$C_RESET"
        read -r choice || exit 0
        printf '\n'

        case "$choice" in
            1)
                one_click_install
                pause_menu
                ;;
            2)
                rebuild_only
                pause_menu
                ;;
            3)
                add_plugins
                pause_menu
                ;;
            4)
                remove_plugins
                pause_menu
                ;;
            5)
                show_plugins
                pause_menu
                ;;
            6)
                restore_default_plugins
                pause_menu
                ;;
            7)
                restore_official_binary
                pause_menu
                ;;
            0)
                printf '已退出。\n'
                exit 0
                ;;
            *)
                warn "无效选项：$choice"
                pause_menu
                ;;
        esac
    done
}

main_menu
