# scripts

VPS 运维脚本集合。当前包含：

| 脚本 | 用途 |
| --- | --- |
| [vps-tune.sh](vps-tune.sh) | Debian 12/13 VPS 系统优化：XanMod、BBR + CAKE、文件句柄、区域智能缓冲 |
| [caddy-manager.sh](caddy-manager.sh) | Debian 系 Caddy APT 安装与 xcaddy 插件管理 |
| [dmit_enable_passh.sh](dmit_enable_passh.sh) | DMIT Debian VPS 的 root 密码登录配置 |

以下介绍 **VPS Tune / VPS 系统优化**，面向独立 VPS / 虚拟机上的代理节点。默认服务名为 `sing-box.service`，可在菜单 7 修改；脚本不安装或修改节点协议、证书和路由配置。

## 复制即运行

在 **Debian 12 或 Debian 13 的 SSH 终端**中复制执行，自动识别 root；普通用户通过 sudo 提权：

```bash
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 https://raw.githubusercontent.com/0xddy/scripts/main/vps-tune.sh -o vps-tune.sh && if [ "$(id -u)" -eq 0 ]; then bash ./vps-tune.sh; else sudo bash ./vps-tune.sh; fi
```

这条命令下载主分支的最新脚本到当前目录并打开菜单；只有在菜单确认“应用”后才写调优配置，重启需单独确认。需要 curl 和系统 CA 证书；普通用户需要 sudo 权限。如果提示找不到 curl，在 root 终端先执行：

```bash
apt-get update && apt-get install -y ca-certificates curl
```

也可以下载后分开运行，方便先查看脚本：

```bash
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://raw.githubusercontent.com/0xddy/scripts/main/vps-tune.sh -o vps-tune.sh
# root 用户
bash ./vps-tune.sh
# 普通用户改用：sudo bash ./vps-tune.sh
```

交互菜单需要终端输入，因此采用“下载文件 → 执行文件”的方式。后续再次打开菜单只需 `bash ./vps-tune.sh`（普通用户加 sudo）。

## 功能概览

- 自动选择 CPU 支持的 XanMod LTS 内核等级；Debian 13 可在高级设置切换 MAIN。
- 持久化设置 BBR + CAKE，并检查默认路由网卡的实际队列。
- 文件句柄默认 1048576，覆盖 PAM、systemd 默认值及指定服务。
- 亚太/欧美节点参考 RTT 100/200 ms，计算缓冲上限并受内存限制；这些是规划值，不是实测地区均值。
- Ookla 测速工具临时下载、校验、隔离运行并清理；不安装 Python/pip 测速依赖。
- 提供方案预览、生效检查、首次备份和配置回滚。

为兼容旧版，系统中的 `singbox-tune` 配置标识、备份目录和互斥锁保留；使用同一套备份与回滚记录。

## 打开菜单

把脚本保存到 Debian 服务器，在脚本所在目录执行：

```bash
sudo bash vps-tune.sh
```

无需记忆调优参数。若已使用 root 登录，可以省略 sudo。脚本需要保存为本地文件，不能通过 `curl | bash` 打开交互菜单。

```text
1. 完整配置（XanMod + BBR/CAKE + 文件句柄）
2. 常规调优（BBR/CAKE，保留当前内核）
3. 智能带宽调优（保留当前内核）
4. 临时测速（只测速，不修改调优配置）
5. 检查实际生效状态
6. 回滚调优配置
7. 参数设置
8. 重启系统
0. 退出
```

首次安装选 **1**，核对方案后选“应用”；完成后可选 **3** 按区域设置智能缓冲，再选 **8** 重启。重新连接后选 **5** 检查。已有 XanMod 的节点可直接选 **3**。方案页默认“仅预览”，回车不会写调优配置；安装与调优完成后返回菜单。重启需要输入 `REBOOT`。

菜单 7 可以设置服务名、文件句柄、内核分支、CPU 等级和常规缓冲上限，设置保留到本次菜单退出。默认服务为 `sing-box.service`，默认文件句柄为 1048576。常规调优和智能调优均配置 BBR + CAKE。

## 多用户节点的智能缓冲

菜单 3 按**节点所在区域**选择：亚太参考 RTT **100 ms**，欧美参考 RTT **200 ms**，再选择临时测速、手动带宽或已有 Ookla JSON。不再要求每次填写单个用户的 RTT。

100/200 ms 是本脚本选定的**容量规划参考值，不是测得的地区平均值**。同一机房到不同省份、运营商的路径差异很大。参考值仅参与缓冲上限计算：2 × BDP → 向上选档 → 内存封顶；内核仍按每条 TCP 连接实际情况自动调整缓冲，不会把连接 RTT 或延迟设成 100/200 ms。

若已收集具有代表性的多地区、各运营商数据，可在高级选项输入代表性 RTT（例如偏高分位 P75/P90，而非极端异常值），并结合实际内存、重传和业务吞吐调整。高级选项也保留原项目亚太/欧美带宽表；这两个兼容模式不使用 RTT。源码审查和公式见 [SMART-BANDWIDTH.zh-CN.md](SMART-BANDWIDTH.zh-CN.md)。

## 临时测速保持环境整洁

Ookla CLI 是原生二进制，不需要 Python venv。脚本使用一次性运行目录：

- 下载固定版本 Ookla 1.2.0，核对 SHA256；amd64 / arm64 分别固定校验值。
- 在临时 chroot 内运行，以 UID/GID 65534 降权；用户配置路径、缓存、证书副本及设备文件都在这个临时根目录中。
- 不安装 pip 包、不通过 APT 安装测速依赖，也不卸载、调用或替换系统已有的 `speedtest` / `speedtest-cli`。
- JSON 解析优先只读使用已有 jq；缺失时下载并校验临时 jq 1.8.1。手动带宽完全不需要 jq。
- 正常完成、失败、收到 Ctrl+C / TERM 退出时清理临时目录。SIGKILL、断电无法触发退出清理，残留位于 `/tmp/vps-tune.*`。

需要系统已有 curl 或 wget、CA 证书，以及 Debian 的 chroot/mknod 等基础工具；受限环境无法建立临时根目录时会停止并提示手动带宽/JSON。这里隔离的是工具及文件，不隔离网络、不启动 Docker 或 Python 环境。下载失败不会转为系统安装。

测速前显示 Ookla 条款及流量提示，只有选择接受才会执行。单次测量最多 180 秒；失败不猜测带宽。测速结束后的方案预览不写调优配置，但实际测速已消耗流量。内核安装和正式调优本身仍会按其用途安装系统软件、写持久配置。

## 自动化入口（可选）

交互使用只需上面的启动命令；已有自动化可以继续使用参数接口，建议显式写 `apply`。无参数且无终端时会拒绝执行。

```bash
# 只读方案；不下载临时工具
sudo bash vps-tune.sh apply --dry-run

# 完整安装，并在成功后自动重启
sudo bash vps-tune.sh apply --reboot

# 欧美节点：参考 RTT 200 ms，无需填写 RTT，保留当前内核
sudo bash vps-tune.sh apply --kernel skip --smart-bandwidth \
  --smart-profile overseas-bdp --bandwidth-mbps 1000 --review

# 修改服务名、手动缓冲上限
sudo bash vps-tune.sh apply --kernel skip --service singbox.service --buffer-mib 8

sudo bash vps-tune.sh check
sudo bash vps-tune.sh rollback --dry-run
sudo bash vps-tune.sh rollback
```

首次修改前的文件保存在 `/var/lib/singbox-tune/`；重复执行保留首次备份。正式应用有互斥锁。CLI 未传入的选项恢复到默认值。

## 内核处理

- 仅对 `amd64` 自动安装 XanMod；根据所有可见 vCPU 的共同特征选择 v1/v2/v3，缺少 AVX 等条件会降档。也可用 `--cpu-level v1` 主动选择较低等级。
- Debian 12 当前使用 LTS；Debian 13 支持 LTS / MAIN。版本号由对应发行版官方仓库决定，不硬编码内核版本。2026-09-26 的本地测试安装了 `6.18.54-x64v3-xanmod1`。
- 新增源使用 HTTPS、独立 `Signed-By` keyring，并核对官方密钥指纹 `D38D7D1DA1349567ADED882D86F7D09EE734E623`。已有 XanMod 源时复用管理员现有配置；错误源应先修复。APT pin 限制该源只提供 XanMod 内核相关包，不批量升级系统。
- 自动引导选择要求已经安装 GRUB。根据实际生成的菜单 ID 选择内核，兼容 Debian 12 / 13；不依赖本地化菜单标题。生成的 GRUB 配置从元包依赖读取内核，后续正常 APT 更新并生成 GRUB 菜单时可跟随新版本。保留现有内核。
- Secure Boot 开启或 EFI 状态无法核实时停止自动切换。发现 DKMS 模块默认停止；确认模块兼容后可传 `--allow-dkms`。其他引导方式、云平台外部指定内核、LXC/OpenVZ 不能套用此自动切换流程。
- 换 VPS CPU 或迁移宿主机后，CPU 特征可能变化；原来安装的 v3 不保证在新 CPU 上可启动。

官方依据：[XanMod 仓库、CPU 等级和分支说明](https://xanmod.org/)。官网当前说明 BBRv3 使用 `tcp_bbr`，sysctl 的算法名称仍是 `bbr`。

## 文件句柄如何生效

默认每进程 soft / hard limit 均为 **1,048,576**；`--nofile` 可设为 65,536～1,048,576。上限不等于预分配资源，也不等于可承载一百万并发连接。

| 层级 | 处理 |
| --- | --- |
| 内核 | `fs.nr_open` 至少为目标值；`fs.file-max` 至少为目标值的 2 倍，保留原来更大的值 |
| PAM 登录会话 | `limits.d` 设置普通用户通配符与显式 root 规则，检查并补充公共 PAM session 的 `pam_limits.so` |
| systemd 系统服务 | `system.conf.d` 的 `DefaultLimitNOFILE`，执行 daemon-reload / daemon-reexec |
| systemd 用户服务 | `user.conf.d` 默认值，并为 `user@.service` 设置启动上限 |
| sing-box | 所选服务的独立 `LimitNOFILE` drop-in，默认服务名 `sing-box.service` |

这里的“全局”是各主要启动路径的持久化默认值。**已经运行的进程和已打开的 SSH 会话不会被追溯修改**；重启系统后新进程读取新值。应用自行降低上限、其他服务显式设置的 LimitNOFILE、更高优先级 drop-in、PAM 用户专用规则仍可能覆盖它。使用 `select(2)` 的旧程序可能不适合高于 1024 的 soft limit。

SSH 登录需要 `UsePAM yes` 才读取 PAM 设置；脚本不擅自改写 sshd 配置。检查新会话和真实服务进程：

```bash
ulimit -Sn
ulimit -Hn
systemctl show sing-box.service -p LimitNOFILE -p LimitNOFILESoft -p MainPID
pid=$(systemctl show sing-box.service -p MainPID --value)
test "$pid" -gt 0 && grep 'Max open files' "/proc/$pid/limits"
```

Docker 容器有独立的进程资源限制。若你的**生产 sing-box 也运行在 Docker**，创建/重建容器时还需指定 `--ulimit nofile=1048576:1048576`，或在 Compose 的该服务下设置：

```yaml
ulimits:
  nofile:
    soft: 1048576
    hard: 1048576
```

仅修改宿主机 limits 文件不会改变现有容器。脚本不改写 Docker daemon 配置，也不重启 Docker。

依据：[systemd 默认限制](https://manpages.debian.org/trixie/systemd/systemd-system.conf.5.en.html)、[PAM limits](https://manpages.debian.org/bookworm/libpam-modules/limits.conf.5.en.html)、[内核文件句柄参数](https://docs.kernel.org/admin-guide/sysctl/fs.html)、[systemd 的 select 限制说明](https://manpages.debian.org/bookworm/systemd/systemd.exec.5.en.html)。

## 吞吐参数

配置保存在 `/etc/sysctl.d/99-zz-singbox-tune.conf`，启动顺序晚于常见的 `99-sysctl.conf`。只应用本脚本自己的文件，不执行全系统 `sysctl --system`。

| 参数 | 默认值 / 目的 |
| --- | --- |
| TCP 拥塞控制、默认队列 | `bbr` + `cake`；当前内核不支持时明确提示等待新内核 |
| 每套接字缓冲上限 | 内存 <1 GiB：4 MiB；1～<2 GiB：8 MiB；2～<4 GiB：16 MiB；≥4 GiB：32 MiB |
| TCP 接收自动调节 | `4096 131072 最大值`，保留较小初始值 |
| TCP 发送自动调节 | `4096 16384 最大值` |
| 通用收发缓冲上限 | `net.core.rmem_max` / `wmem_max` 与上述最大值相同，允许 UDP/QUIC 应用申请缓冲 |
| 队列 | `somaxconn=4096`，SYN backlog / netdev backlog 为 8192 |
| TCP 基础能力 | 自动接收缓冲、窗口扩大、SACK、SYN cookies 开启 |
| PMTU 黑洞 | `tcp_mtu_probing=1`，出现黑洞时才探测 |

上述缓冲最大值是按需上限；应用的 `SO_RCVBUF` / `SO_SNDBUF`、自身并发与用户态内存仍影响用量。例如 1 Gbit/s × 100 ms 的带宽时延积约为 12.5 MB，但把每连接上限调大并不保证更快。普通模式最高自动选择 32 MiB，可手动指定 `--buffer-mib 64`；显式启用智能模式后，依据带宽、模式和内存可选择最高 64 MiB。

BBR 控制内核 TCP。Hysteria2 / TUIC 等 QUIC 协议使用用户态拥塞控制，不能把启用 BBR 说成其全部流量自动获得 BBRv3。脚本不修改协议的带宽声明、拥塞算法，也不启用 TCP Brutal。

默认保持 IP 转发、防火墙、IPv6、端口范围、TIME_WAIT 重用、连接追踪、swap、网卡 MTU 和 offload 的原配置。它们需要结合具体拓扑与负载决定。`default_qdisc` 不会替换已存在的网卡队列，重启后用 `tc qdisc show` 查看实际队列；云平台的 `mq` 子队列或 `noqueue` 设备需要按接口判断。

安装 XanMod 后自动写入 `net.ipv4.tcp_congestion_control=bbr`、`net.core.default_qdisc=cake`，并配置开机加载 `tcp_bbr`、`sch_cake`。当前内核支持时立即更新这些默认值；新装内核必须重启后才开始运行。CAKE 使用默认的 unlimited 模式，不会根据 Speedtest 峰值自动限速，也不创建 ingress/IFB 整形。

`default_qdisc` 影响新建队列。已有网卡队列在本次 SSH 会话中不强制替换；重启后检查实际队列。物理多队列网卡可以是 `mq` 根队列加 `cake` 子队列，`lo/veth` 等虚拟设备可能忽略该默认值。网络管理器也可能覆盖它，检查未通过时会返回待核实状态。[内核 default_qdisc 说明](https://cdn.kernel.org/doc/html/latest/admin-guide/sysctl/net.html#default-qdisc)

依据：[Linux TCP/UDP sysctl 文档](https://docs.kernel.org/networking/ip-sysctl.html)。

## 检查与回滚边界

`check` 显示当前内核、目标内核、每项 sysctl 的实际值/目标值、systemd 默认值及真实服务进程的文件限制。存在差异或无法验证（例如服务没启动、容器没有 systemd PID 1）返回 **2**；错误返回 **1**。检查还会验证 IPv4/IPv6 默认路由网卡的实际 CAKE 队列，包括 mq 的子队列；非 CAKE、混合队列、noqueue、无默认路由或无法读取均返回 2。返回 0 仅表示已检查项目匹配，仍应核实新 SSH 会话。

回滚会恢复被修改文件的首次备份、移除本脚本新建的配置文件，并尝试恢复记录的运行时 sysctl。不会卸载已安装的软件包、删除任何内核、恢复旧连接的拥塞控制、强制修改现有进程限制或自动重启。回滚当前内核需先在 GRUB 中选择 Debian 原内核再重启；确认成功后才考虑移除 XanMod。

如果管理文件后来被手动修改，脚本会拒绝覆盖或回滚该文件，要求先备份并整理变更。运行中断可能留下部分配置或已安装的软件包；错误日志给出备份目录，不伪装成全部成功。回滚需要在管理员无并发修改的维护窗口执行。

## 本地 Docker 测试

Windows PowerShell，在仓库根目录执行：

```powershell
# 默认真正安装 XanMod 内核包，执行配置测试和真实 sing-box 转发测试
powershell -ExecutionPolicy Bypass -File .\tests\run-docker.ps1

# 只跳过内核包下载/安装
powershell -ExecutionPolicy Bypass -File .\tests\run-docker.ps1 -SkipKernelInstall
```

脚本创建 Debian 12 / 13 的一次性容器。每个容器约需 1 GiB 磁盘和联网下载软件包；测试退出后删除容器，镜像保留。日志写入 `test-results/`。测试包括菜单输入与真实 TTY、区域参考 RTT、BBR/CAKE 持久配置和队列判断、智能带宽算法、离线 JSON、本地测量适配器，以及官方临时二进制版本运行和退出清理；不会自动发起公网测速。不使用特权模式、host 网络或宿主系统目录的写入挂载。

`--container-test` 只允许在容器中使用：可真正安装软件包、生成 initramfs、写容器内配置，但跳过运行时 sysctl、模块加载、systemd 操作和 GRUB 引导修改。普通 apply 检测到容器会拒绝执行。

已完成的验证见 [TEST-REPORT.zh-CN.md](TEST-REPORT.zh-CN.md)；本地复现生成的日志位于 `test-results/`。**Docker 共用宿主机内核，所以这些测试不能证明 XanMod 真实开机、systemd PID 1 下的行为或公网吞吐提升。** GRUB 使用明确标注的菜单 fixture 测试；PAM 与 sing-box 转发使用实际进程测试。完整内核启动验收需在可重启的 KVM / 实机上执行。
