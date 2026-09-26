# 智能带宽优化：源码审查与集成说明

审查对象：byJoey/Actions-bbr-v3，固定提交 `22ebda7be4fdca46eb2068bb14056579dac2ee6d`（2026-09-22）。审查日期：2026-09-26。仅阅读源码，没有运行上游安装脚本。

## 原项目实际如何计算

它先运行 Ookla Speedtest，读取上传与下载带宽。随后用户选择亚太/美欧档位并填写 RTT，脚本用**上传带宽 + 地区档位**查表，再受内存上限约束；同一个结果用于 `rmem_max`、`wmem_max`、`tcp_rmem` 和 `tcp_wmem` 的最大值。

**关键发现：RTT 没有参与缓冲区计算。** `SMART_RTT_MS` 用于输入和展示，`calculate_smart_buffer_mb()` 接收的是上传带宽、地区代码和内存上限。它是一次性经验档位设置，没有持续测量、反馈调节或自动寻找最优值。

源码位置：[查表和内存限制](https://github.com/byJoey/Actions-bbr-v3/blob/22ebda7be4fdca46eb2068bb14056579dac2ee6d/install.sh#L236-L292)、[RTT 输入与配置应用](https://github.com/byJoey/Actions-bbr-v3/blob/22ebda7be4fdca46eb2068bb14056579dac2ee6d/install.sh#L491-L628)。

| 上传带宽（Mbit/s） | 亚太档（MiB） | 美欧档（MiB） |
| --- | ---: | ---: |
| <500 | 8 | 16 |
| 500～<1000 | 12 | 48 |
| 1000～<2000 | 16 | 64 |
| 2000～<5000 | 24 | 64 |
| 5000～<10000 | 28 | 64 |
| ≥10000 | 32 | 64 |

原项目内存约束为：<512 MiB 内存时上限 16 MiB，512～<1024 MiB 时 32 MiB，≥1024 MiB 时 64 MiB。还会设置 BBR/fq、`tcp_limit_output_bytes=4194304` 和 `tcp_slow_start_after_idle=0`。

本次审查还确认了这些边界：

- 智能模式的这条调用路径只设置 `default_qdisc`，不会调用另外菜单所用的接口 root qdisc 替换函数。
- 下载带宽主要用于展示；实际缓冲计算使用上传值。
- 低于 1 Mbit/s 的测量结果经去除小数后可能归入无效值，并被默认成 1000 Mbit/s。
- 准备测速工具会尝试卸载 Python 版 speedtest-cli，并可能删除现有 `speedtest` 可执行文件。
- 自动测速会传入接受 Ookla 许可与 GDPR 条款的选项。

测速相关源码：[工具安装和结果处理](https://github.com/byJoey/Actions-bbr-v3/blob/22ebda7be4fdca46eb2068bb14056579dac2ee6d/install.sh#L312-L451)。

## 集成到当前脚本的实现

保留现有 XanMod、文件句柄、备份、检查和回滚逻辑。菜单 3 进入智能调优；常规调优使用原来的内存分档，自动化仍可传 `--smart-bandwidth`。计算与解析代码独立编写，地区档位参考了上述公开算法。

| 模式 | 计算方法 | 适用方式 |
| --- | --- | --- |
| `asia-bdp`，菜单默认 | 100 ms 规划 RTT，按 2 × BDP 估算 | 亚太多用户节点；不是地区实测均值 |
| `overseas-bdp` | 200 ms 规划 RTT，按 2 × BDP 估算 | 欧美多用户节点；不是地区实测均值 |
| `bdp`，CLI 兼容默认 / 菜单高级选项 | 带宽 × 真实 RTT，取 2 倍 BDP、向上选档，然后受内存限制 | 已知代表性 TCP 业务路径的带宽和 RTT |
| `asia` | 参考原项目亚太带宽表，再受本脚本内存限制 | 想采用较保守的经验档位 |
| `overseas` | 参考原项目美欧带宽表，再受本脚本内存限制 | 想采用原项目较大的经验档位 |

BDP 模式：

```text
BDP_bytes = bandwidth_Mbit/s × 1,000,000 ÷ 8 × RTT_ms ÷ 1000
目标上限 = 2 × BDP，向上选 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 MiB
最终上限 = min(目标上限, 内存保护上限)
```

超过最高档时保留未截断需求用于诊断，实际仍不超过 64 MiB。2 倍 BDP 是本脚本选定的初始估算，不能保证最优；多连接代理不应把“整条线路的带宽”理解为每条连接都会获得同样带宽。设置的是每套接字上限，不是总内存预算。

新模式的内存保护上限：

| 系统内存 | 每套接字最大缓冲 |
| --- | ---: |
| <512 MiB | 4 MiB |
| 512～<1024 MiB | 8 MiB |
| 1024～<2048 MiB | 16 MiB |
| 2048～<4096 MiB | 32 MiB |
| ≥4096 MiB | 64 MiB |

例如 **1000 Mbit/s、150 ms、4 GiB 以上内存**：BDP 约 17.88 MiB，2 倍约 35.76 MiB，向上选为 **48 MiB**；同样参数在 1 GiB VPS 上被限制为 **16 MiB**，并提示内存上限可能限制高 BDP 流量。这些是计算示例，没有测量你的实际服务器。

内存取 Debian 系统的 `/proc/meminfo`。容器测试可能看到 Docker VM 的总内存；内存分档边界另以固定输入测试，不把容器 `--memory` 参数当作已检测的系统 RAM。

不同路径需要不同窗口，不能仅根据地区推断真实链路条件。相关背景可参阅 [ESnet 的 Linux 缓冲区与多流调优说明](https://fasterdata.es.net/host-tuning/linux/)。

## 多用户场景的 RTT

全局设置不应依赖单一客户端样本。菜单按节点机房区域使用 100/200 ms 规划值，这两个值是可解释的初始假设，不代表对中国各省和运营商做过测速。区域预设禁止同时传 `--rtt-ms`，自定义需要选择 `bdp`。

1000 Mbit/s、内存 ≥4 GiB 时：亚太预设计算为 24 MiB，欧美预设计算为 48 MiB。不是每连接预分配这么多内存；TCP 自动调节仍开启。多连接总用量必须观察，内存封顶只限制每套接字，并非全局内存预算。

有真实样本时，应覆盖不同运营商、地区和时段。偏高分位 RTT 可作为照顾较远用户的规划输入，但 P75/P90 也是运维选择，不能据此保证所有连接达到目标吞吐。两侧路径、丢包、CPU 和共享出口也会限制代理速度。

## 用法

推荐运行 `sudo bash vps-tune.sh`，菜单 **3 → 亚太/欧美 → 选择带宽来源 → 预览/应用**。菜单 **1** 完成 XanMod + BBR/CAKE 基础配置，菜单 **4** 单独临时测速。以下命令保留给自动化：

```bash
sudo bash vps-tune.sh apply --kernel skip --smart-bandwidth \
  --smart-profile asia-bdp --bandwidth-mbps 1000 --review
sudo bash vps-tune.sh apply --kernel skip --smart-bandwidth \
  --smart-profile overseas-bdp --bandwidth-mbps 1000 --review
```

已经部署过当前调优脚本的节点，仅更新网络调优可使用 `--kernel skip`。下面的带宽/RTT 需换成你的线路数据：

```bash
# 只预览；例子是 1 Gbit/s、150 ms
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --bandwidth-mbps 1000 --rtt-ms 150 --dry-run

# 应用同一方案；不主动重启服务器/服务
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --bandwidth-mbps 1000 --rtt-ms 150

# 初次完整安装：同时安装 XanMod、设置文件句柄和智能缓冲，成功后重启
sudo bash vps-tune.sh --smart-bandwidth \
  --bandwidth-mbps 1000 --rtt-ms 150 --reboot

# 使用参考原项目的亚太或美欧查表模式；RTT 不参与这两种模式
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --smart-profile asia --bandwidth-mbps 1000
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --smart-profile overseas --bandwidth-mbps 1000
```

`--bandwidth-mbps` 是希望针对的瓶颈/出口带宽，单位为十进制 Mbit/s，支持小数；它不会限速或改变云服务商的带宽配额。`--rtt-ms` 应取代表性的客户端↔节点 TCP 连接 RTT，例如从活动连接的 `ss -tin` 输出观察；V2Ray 客户端的“真连接延迟”可能还包含握手或应用层开销，不能直接等同于纯 TCP RTT。代理另一侧路径不同，最终需要结合真实业务观察。

Ookla 接入方式：

```bash
# 导入已取得的官方 Ookla JSON；不发起公网测速
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --speedtest-json ./speedtest-result.json --rtt-ms 150

# 下载并校验临时官方 Ookla CLI，隔离运行一次，然后生成配置
# 此选项表示你接受 Ookla 许可/GDPR 条款；测速会消耗公网流量
sudo bash vps-tune.sh --kernel skip --smart-bandwidth \
  --speedtest --rtt-ms 150 --accept-speedtest-terms
```

测速采用临时原生二进制环境，不使用 Python venv。固定 Ookla 1.2.0，校验 SHA256 后在一次性 chroot 中以 UID/GID 65534 运行；配置和缓存所在用户目录也在临时根目录内。正常退出、失败和 Ctrl+C / TERM 会清理。不会使用或替换系统已有的测速 CLI，也不通过 APT/pip 安装测速依赖。

JSON 优先读取已有 jq；没有时下载固定 jq 1.8.1 静态工具到临时目录并校验 SHA256。`--dry-run` 保持无下载，因此解析 JSON 需要已有 jq；菜单方案预览允许准备临时工具。手动带宽模式没有 jq 依赖。原生工具仅支持 amd64/arm64，受限 chroot/mknod 或缺少系统 CA 时提示改用手动输入。SIGKILL/断电不能执行清理，残留在 `/tmp/vps-tune.*`。

官方 JSON 的 `upload.bandwidth` / `download.bandwidth` 单位是 **bytes/s**，脚本转换为 Mbit/s；上传值进入计算，下载值只展示。单位已对照 [Ookla 1.2.0 官方包](https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz) 内 `speedtest.md` 的 OUTPUT FORMATS / OUTPUT 说明核实。测速结果的 `ping.latency` 不会读取为业务 RTT。不同测试服务器的出口峰值也不等于用户经过代理的端到端可用带宽。

实时测速有 180 秒超时，仅执行一次；版本检测有 10 秒超时。失败后停止并提示提供已知带宽，不猜测默认带宽，不自动重装程序。dry-run 和容器测试拒绝实际测速；使用手动值/JSON 验证算法。三个带宽来源互斥，智能模式与显式 `--buffer-mib` 值互斥。

## 未照搬的参数与生效边界

保留当前 TCP 初始缓冲 `rmem=131072` / `wmem=16384`，只改变自动调节的最大值和通用收发缓冲上限。按用户指定统一持久化配置 BBR + CAKE，并添加 `sch_cake` 开机加载；CAKE 默认 unlimited，不把测量带宽自动变成整形速率。地区档位名称并不自动识别服务器或用户所在地。

本次没有全局关闭 `tcp_slow_start_after_idle`，也没有强制改写 `tcp_limit_output_bytes`。内核文档说明前者控制空闲后的拥塞窗口处理；后者约束每 TCP 套接字在本机 qdisc/设备侧的排队，其当前文档默认就是 4 MiB。它们不能单凭地区/带宽推断应全局更改，且不应和自动缓冲上限混为一谈。[Linux 参数说明](https://docs.kernel.org/networking/ip-sysctl.html)

本功能也不热替换已有网卡 qdisc，不调整 NIC 队列或套用原项目极限测速模式。全局 TCP 上限不是 Hysteria2 / TUIC 的用户态 QUIC 拥塞算法；通用缓冲上限只允许这些应用申请更大的缓冲。

生成的 sysctl 文件带有 `Buffer plan` 注释，记录来源、模式、带宽、RTT、估算值、内存上限和最终值。`check` 会展示它，回滚仍使用首次备份。重新运行普通 apply 会回到普通内存分档；切换这些模式不需要手动清理旧智能配置。

## Docker 验证

菜单、区域规划、原算法、JSON、BBR/CAKE 配置及检查、临时工具隔离和清理均在 Debian 12/13 Docker 内测试。版本探测使用真实官方 Ookla 二进制，但没有接受许可、执行公网测量。JSON 测量流程采用明确的本地适配器 fixture。测试数量和本轮/历史记录见 [TEST-REPORT.zh-CN.md](TEST-REPORT.zh-CN.md)，原始日志位于 `test-results/`。

Docker 共用宿主内核，没有改写宿主 sysctl 或 qdisc，不能证明重启进入 XanMod、真实 CAKE 生效或公网吞吐提升。
