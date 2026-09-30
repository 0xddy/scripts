系统优化：

```bash
curl -fsSL https://raw.githubusercontent.com/0xddy/scripts/main/vps-tune.sh -o vps-tune.sh && sudo bash vps-tune.sh
```

`vps-tune.sh` 支持 Debian 12/13。新的基础配置默认使用 BBR + FQ；已有
CAKE/FQ_CODEL 选择会保留。安装 XanMod 仍沿用原有流程；只调网络及系统限制时使用
`--kernel skip`。

按带宽和 RTT 调整缓冲（先预览，再移除 `--dry-run` 应用）：

```bash
sudo bash vps-tune.sh apply --kernel skip --smart-bandwidth \
  --bandwidth-mbps 500 --rtt-ms 150 --dry-run
```

这里的带宽是目标出口带宽，RTT 应代表实际业务路径；Ookla 就近测速的 RTT
不能代表跨境业务 RTT。原有区域规划、大陆 TCP RTT 探测、测速 JSON 导入和菜单仍可使用。

计算参考 [tcpfit 的实际实现](https://github.com/Kylin010/tcpfit/blob/76331588af487a973d3445a1bf8bba7037d566ca/tcpfit.sh)：

- `BDP = Mbps × 1,000,000 / 8 × RTT_ms / 1,000` 字节。
- 单方向 socket 缓冲目标为 `2 × BDP + 2 MiB`，向上取整到 MiB，目标最低 4 MiB。
- TCP 全局队列低水位、压力水位、上限分别按 RAM 的 1/16、1/8、1/4 计算，使用实际
  `getconf PAGESIZE` 换算页数；每个方向的缓冲上限不超过全局上限的 1/8，最多 256 MiB。
- 内存预算优先于 4 MiB 下限。手动缓冲值也必须在预算以内。TCP 原有初始收/发缓冲值
  保持 128 KiB / 16 KiB，让内核按需增长，避免统一提高初始额度。
- 启用 `tcp_slow_start_after_idle=0`，保留 TCP 指标缓存、SACK/DSACK、timestamps、
  接收自动调节和 MTU 黑洞探测。新增参数随原有配置一起快照和回滚。

例如 500 Mbps / 150 ms / 1 GiB RAM：BDP 约 8.94 MiB，目标上取整为 20 MiB，
单方向预算上限 32 MiB，因此选择 20 MiB。更高的参数并不保证更高吞吐；`tcp_mem`
也不覆盖应用内存、全部队列内存或 UDP，不能防止所有 OOM。

未照搬固定 `initcwnd=32`、`tcp_tw_reuse=1`、`vm.min_free_kbytes=32768`、
缩短 FIN 超时、全局 Fast Open 或已废弃的 `tcp_adv_win_scale`。
这些选项需要具体路径、应用或内核依据，参数语义参见
[Linux 内核文档](https://docs.kernel.org/networking/ip-sysctl.html)。

可选的出口整形与测量：

```bash
# 显式建立可识别的 FQ 基线；会影响默认出口网卡，使用 FQ 默认参数。
sudo bash vps-tune.sh queue --qdisc fq

# 对端必须是你有权测试的 iperf3 服务，默认端口 5201。
# 先查看扫描计划；扫描会临时改变整张出口网卡的队列并消耗真实流量。
sudo bash vps-tune.sh sweep --peer YOUR_IPERF_SERVER --nominal-mbps 500 --dry-run
sudo bash vps-tune.sh sweep --peer YOUR_IPERF_SERVER --nominal-mbps 500 --accept-traffic

# 扫描只给建议，不自动持久化；按实际建议填写速率，而非照抄 480。
sudo bash vps-tune.sh shape --rate-mbps 480
sudo bash vps-tune.sh shape --off

sudo bash vps-tune.sh check
sudo bash vps-tune.sh rollback
```

整形使用 HTB 聚合上限和 FQ 叶子，突发额度为 `max(32768, Mbps × 500)` 字节。
扫描需要已安装 `iperf3`、`jq` 和 `iproute2`，不会自动寻找公共测速对端或安装这些测量工具。
它先测无整形基线，仅在估算重传比例较高时继续扫描，并在输出建议前复测。
重传估算阈值为 0.1%；最多 28 次采样，每次 8 秒测量加 2 秒预热，另有等待和超时。
找到低重传与高重传区间后细扫，候选速率留 3% 余量。建议必须通过两次复测：
吞吐均达到最佳基线的 98%，重传估算均降低至少 80% 且不超过 0.1%；基线波动过大则不给建议。
这个门槛允许最多 2% 吞吐下降，目的是在保留吞吐的同时降低重传，并不保证提速。
高重传也可能来自路径拥塞、对端或虚拟机 CPU 瓶颈；低重传只说明当前样本没有支持整形的证据。
iperf3 重传比例不是真实丢包率，也不能证明存在运营商限速器。

为了可以恢复原状态，整形与扫描只接管本脚本显式建立的标准单根 FQ 或自身 HTB。
多队列 `mq`、第三方整形、外部修改或分类规则需要人工规划；拒绝执行时不会替换这些队列。
扫描完成、失败或收到可捕获的退出信号后会尝试恢复扫描前状态。
`shape --off` 恢复本脚本 FQ 并保留基础调优；完整 `rollback` 还恢复备份的配置及 sysctl。
更早的 `queue` 切换仅保存审计快照，回滚后需重启重新建立原网卡队列，不承诺恢复任意自定义队列参数。
已安装的内核和软件包不自动卸载。回滚运行值失败会保留状态并报错，可排除原因后重试。

开发回归测试（不产生公网测速流量）：

```bash
bash tests/test-vps-tune.sh
bash tests/test-iperf-json.sh "$PWD/vps-tune.sh"   # 需要 jq
python3 tests/test-shaping-signals.py vps-tune.sh
shellcheck vps-tune.sh tests/*.sh
```

`tests/integration-container.sh` 用于一次性 Debian 12/13 容器，镜像需有 procps、
kmod、iproute2、libpam-runtime 等基础依赖，验证真实配置文件的应用与回滚。
`tests/integration-shaping-container.sh` 还需容器的 `--network none --cap-add NET_ADMIN`，
通过独立网络命名空间里的 dummy 网卡验证真实队列与故障恢复。两者均不得在生产宿主运行。

Caddy 安装与插件管理：

```bash
curl -fsSL https://raw.githubusercontent.com/0xddy/scripts/main/caddy-manager.sh -o caddy-manager.sh && sudo bash caddy-manager.sh
```

DMIT 启用 root 密码登录：

```bash
curl -fsSL https://raw.githubusercontent.com/0xddy/scripts/main/dmit_enable_passh.sh -o dmit_enable_passh.sh && sudo bash dmit_enable_passh.sh
```
