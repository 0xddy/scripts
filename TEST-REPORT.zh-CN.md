# 本地 Docker 测试记录

本文保留开发阶段的测试记录；历史原始日志保存在本地交付包中，没有提交到此仓库。运行 `tests/run-docker.ps1` 会在仓库内重新生成 `test-results/` 日志，该目录已加入 Git 忽略规则。

## 仓库发布前复核

2026-09-26，将待提交脚本和 tests 复制到 Debian 12/13 的非特权 Docker 容器，再次执行 Bash 语法、ShellCheck、配置回归 11 组、智能带宽 8 组、菜单 9 组、BBR/CAKE 3 组，两版各通过 31 组。PowerShell 测试入口语法通过。本轮未重跑内核安装、临时运行环境或公网测速；这些验证的范围以对应历史记录为准。

## 名称调整

入口改为 `vps-tune.sh`，菜单显示 VPS 系统优化，文档和 Docker 测试入口同步更新。系统配置/备份路径保留旧标识以兼容已部署版本，算法与调优行为未变。历史原始日志不改写，其中的旧脚本名属于测试时记录。

改名后在 Debian 12/13 一次性 Docker 容器核对 Bash 语法、ShellCheck、帮助、只读方案与菜单启动/退出，全部通过；PowerShell 测试入口语法通过。本次未重复内核安装或公网测速。

## 最新：中文菜单、区域参考 RTT、BBR + CAKE、临时测速环境

2026-09-26，在本地 Debian 12/13 的两个非特权 Docker 容器执行，两版各通过 **36 组**：

| 测试 | 每版组数 | 主要覆盖 |
| --- | ---: | --- |
| 原有配置回归 | 11 | 持久配置、PAM、文件句柄、幂等、回滚、CPU 选择 |
| 智能带宽 | 8 | BDP、地区表、区域预设、内存上限、JSON 与失败处理 |
| 菜单 | 9 | 无参数真实 TTY、输入校验、预览、应用、设置、回滚、EOF、区域选择 |
| BBR + CAKE | 3 | 普通/智能配置、启动模块、回滚；CAKE/mq/混合/noqueue/失败状态判断 |
| 临时测速环境 | 5 | 成功、失败、校验失败、INT 清理；软件包和用户目录不变 |

临时运行环境使用下载自官方地址并固定 SHA256 的真实 Ookla 1.2.0.84 与 jq 1.8.1。Ookla 在 chroot/UID 65534 中实际运行 `--version`，jq 在临时目录中执行；未接受 Ookla 测速条款、未执行公网测量。文件退出后消失；`dpkg-query` 软件包列表及 `/root` 文件哈希保持一致。ARM64 工具的下载校验值已核对，但未在 ARM64 上执行。

测试镜像复用了前一轮 Debian 镜像，并复制当前脚本。临时 jq 测试先在无系统 jq 环境验证，其后仅在一次性测试容器放置 jq 以运行离线 JSON 回归。新版 Dockerfile 会在构建测试镜像时安装 jq；测试仍强制覆盖临时 jq 的备用路径。正式脚本没有引入 APT/pip 测速安装步骤。

本轮没有重新安装内核，原始 XanMod 安装验证见下方历史记录。CAKE 队列判断使用 fixture，运行时宿主 sysctl/qdisc 不变；需要重启实机/KVM 后在菜单 5 核实。主脚本 Bash 语法和 ShellCheck、PowerShell 入口语法均通过。

应用欧美参考 RTT 200 ms / 1000 Mbit/s 方案后，两版各以真实 sing-box 1.14.2 完成 64/64 次 SOCKS5 请求、并发 16、总计 64 MiB，长度和 SHA256 全部通过。真实进程文件句柄上限为 1048576。回环功能测试耗时分别为 1.054 / 1.089 秒，不能用于推断公网带宽或 CAKE 性能。

最新日志名称含 `menu`，另有 `debian-12/13-cake.log`、`debian-12/13-isolated-runtime.log`。下面按历史顺序保留前两轮记录，旧日志中的 fq/安装式适配器描述不代表最终脚本配置。

## 智能带宽集成后的增量测试

本次审查上游提交 `22ebda7be4fdca46eb2068bb14056579dac2ee6d` 并集成智能模式后，重新建立 Debian 12 / 13 Docker 测试环境：

- 两版系统各通过新增智能带宽测试 **8 组**，包含 BDP、地区带宽表边界、内存封顶、小数、参数校验、JSON 单位换算、测速 ping 隔离、重复执行/模式切换/回滚，以及测速适配器本地模拟。
- 两版系统各通过原有配置回归 **11 组**。本轮未重复安装内核，依赖已安装内核的 GRUB fixture 未运行。
- Bash 语法和主脚本 ShellCheck 通过；PowerShell 测试入口新增智能测试步骤。
- 两版系统在生成智能配置后，各用真实 sing-box 1.14.2 完成 64 次 SOCKS5 请求（并发 16、总计 64 MiB），长度和 SHA256 校验全部通过；真实进程句柄上限仍为 1048576。
- 没有执行真实公网 Ookla 测速，没有应用宿主 sysctl。算法与 CLI 适配器测试不等于公网吞吐收益验证。

源码审查和用法见 `SMART-BANDWIDTH.zh-CN.md`。增量日志为 `debian-12/13-smart-bandwidth.log`、`debian-12/13-integration-smart-regression.log` 和 `debian-12/13-smart-proxy-smoke.log`。下方保留第一版的完整安装与测试记录。

## 第一版完整安装记录

测试日期：2026-09-26。Windows 本地 Docker Desktop 4.54.0，Docker Engine 29.1.2，linux/amd64；容器实际共用 WSL2 内核 `6.6.87.2-microsoft-standard-WSL2`。

测试通过本地 Docker 命令，在专用的一次性 Debian 12 / 13 容器中实际执行。随包提供的 PowerShell 复现入口已通过语法检查；本次没有重新构建其 Dockerfile 来重复全部下载。两个环境安装的依赖与 Dockerfile 中的列表一致。

| 项目 | Debian 12 | Debian 13 |
| --- | --- | --- |
| Bash 语法、主脚本 ShellCheck | 通过 | 通过 |
| 官方 XanMod APT 密钥、签名验证与依赖解析 | 通过 | 通过 |
| 实际安装 XanMod LTS 元包、image、headers | `6.18.54-xanmod1-0` | `6.18.54-xanmod1-0` |
| 实际内核镜像 | `6.18.54-x64v3-xanmod1` | 同左 |
| 生成非空 initramfs | 通过，约 44 MiB | 通过，约 48 MiB |
| 重复执行已安装内核的路径 | 通过 | 通过 |
| 配置/回滚集成测试 | 12 组通过 | 12 组通过 |
| root / nobody 的真实 PAM 会话 | soft / hard 均为 1048576 | 同左 |
| 普通用户实际打开 FD | 65536 个 | 65536 个 |
| sing-box 版本 | 1.14.2 | 1.14.2 |
| 实际 sing-box 进程 FD soft / hard | 1048576 / 1048576 | 同左 |
| SOCKS5 实际转发与 SHA256 校验 | 64 / 64 成功 | 64 / 64 成功 |
| 测试并发与总数据量 | 并发 16，总计 64 MiB | 同左 |

每版系统的 12 组集成测试覆盖：

1. Bash 语法和 ShellCheck。
2. dry-run 不写配置、非法参数、默认拒绝容器、容器禁止重启，以及 Debian 12 拒绝 MAIN。
3. 容器测试模式不改变运行时 sysctl。
4. 重复 apply 的内容校验值完全一致，备份清单不重复。
5. systemd 系统/用户默认值与服务 drop-in 的离线解析。
6. 父进程 soft limit 降到 1024 后，root 和 nobody 的 PAM 新会话提升到 1048576。
7. 普通用户真实打开并关闭 65536 个文件描述符。
8. `check` 在无法完成运行时验证时返回 2。
9. 重复应用和回滚均拒绝覆盖后续人工修改。
10. 回滚恢复原文件、恢复 PAM 内容，并移除本脚本新建的配置。
11. CPU v1 / v2 / v3、混合 vCPU 和缺少 AVX 的检测 fixture。
12. GRUB 菜单 ID 选择、元包更新后跟随新版本的 fixture。

SOCKS5 测试启动真实 sing-box，以 nobody 用户运行并读取真实 `/proc/PID/limits`。每请求下载 1 MiB 本地 HTTP 数据，经 SOCKS5 转发后核对长度与 SHA256；64 次请求全部成功。记录耗时 Debian 12 为 1.083 秒、Debian 13 为 1.137 秒，仅是回环环境功能测试耗时，不能据此推导公网带宽或调优收益。

未验证：真实重启进入 XanMod、真实 GRUB 磁盘启动、Secure Boot / DKMS 硬件组合、宿主 systemd PID 1 的重新执行和服务继承、真实网卡 fq 队列、跨公网吞吐/延迟/丢包、Hysteria2/TUIC 协议端到端行为。容器没有写宿主 sysctl，也没有使用特权模式。实际节点需重启后运行 `check`，并在同一线路、相同负载下做调优前后对比。

基础镜像摘要：

```text
debian:12-slim
sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

debian:13-slim
sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
```

完整日志在 `test-results/`。`kernel-install` 是真实首次安装日志，`kernel-reapply` 是重复安装/应用日志，`integration` 是最终集成验证日志，`singbox-install` 是官方 sing-box APT 安装日志，`proxy-smoke` 是实际代理转发日志。

另外在 Debian 12 验证了复用既有签名仓库：不产生重复源，回滚保留管理员原有源。对应日志为 `debian-12-existing-source.log`。
