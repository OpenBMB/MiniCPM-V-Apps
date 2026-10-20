# pwrbench —— iOS 整机功率测量套件

配套批量基准测试使用，回答两个问题：

- **(a)** GPU 计算和 SSD 专家搬运，谁占的功耗大头？
- **(b)** 因为要做 SSD 搬运，整机功耗多出了多少？

## 为什么在主机侧，而不是像批量测试那样集成进 App

整机功率来自设备 `diagnosticsd` 服务暴露的 `PowerTelemetryData`，
**只有主机侧（usbmux / 网络）能访问**。

App 内唯一同类的接口是 IOReport 的 `Energy Model → GPU Energy` 通道。
该通道在 iOS 17.7 上**确实存在**（可从 `AGXAccelerator` 的 `IOReportLegend` 读到），
但订阅被系统策略拒绝：

```
System Policy: <process> deny(1) iokit-open IOReportUserClient
```

传入 `IOServiceGetMatchingService("AGXAccelerator")` 的服务句柄重试同样失败。
故功率采集只能放在主机侧；App 负责提供 CPU 能量（`ri_energy_nj`）、
GPU 时长（`gpu_time`）、磁盘字节与逐 case 计时。

> 顺带记录两个已被排除的方案，避免重复尝试：
> - `pymobiledevice3 developer dvt energy`：返回 `energy.gpu.cost`，但取值只有
>   `0 / 1000` 两档，是 Energy Impact 等级，不是焦耳。
> - `Amperage` / `InstantAmperage`：大多数时候为 0，不是负载的线性反映。
>   真正跟负载走的是 `PowerTelemetryData`。

## 前置条件

| 项 | 说明 |
|---|---|
| macOS + Xcode 命令行工具 | 提供 `xcrun devicectl` |
| Python 3.8+ | |
| `pymobiledevice3` | `pip install pymobiledevice3`（建议锁版本） |
| 设备已信任、已安装 App | App 需用**你自己的**开发者账号签名 |
| 供电 | 推荐接**已知功率**的充电器；充电器吃得下负载时 `SystemPowerIn` 直接是整机功率 |

## 用法

### 1. 先确认字段可用

```bash
python3 pwrbench.py probe --device <UDID>
```

会打印 `SystemPowerIn` / `SystemCurrentIn` / `SystemVoltageIn` / `BatteryPower`，
并用 `I × V = P` 做一次自校验。

### 2. 采数据

```bash
python3 pwrbench.py run \
    --device <UDID> \
    --bundle com.your.bundle \
    --plan idle,A,B \
    --pairs 3 \
    --block-seconds 150 \
    --cooldown 120 \
    --tokens 256 --case 2 \
    --out results/
```

- `--bundle`：目标 App 的 Bundle ID。**仓库里不写死任何具体包名**，缺省值是占位符
  `com.example.MiniCPMVDemo`，请用 `--bundle` 传入你自己的构建，或设一次
  `export PWRBENCH_BUNDLE=<你的 Bundle ID>`。它只用于主机侧 `devicectl` 启停 App 与拷贝文件，
  与 App 界面里跑批无关（App 自身不读取自己的 bundle id）。
- `--plan`：条件序列。`A` 默认（有 SSD 读）、`B` 是 `-moeSkipRead`（不读盘）、
  `C` 是 `-moeDummyRead`、`D` 是 `-moeDecodeWindow 0`、`F` 是 `-moeNoMmap`、
  `idle` 是模型驻留但不推理。
- `--cooldown`：块间冷却。**不要设成 0** —— 连续满载会让设备积热降频，
  既污染数据也有风险。
- 采样结束后自动出报告。

### 3. 只重算已有数据

```bash
python3 pwrbench.py analyze --out results/
```

产出 `results/power.jsonl`（原始样本）与 `results/report.md`（表格 + 配对差值）。

## 为什么必须配对交替，而不能两组各跑一次

`PowerTelemetryData` 每约 **20 秒**刷新一次，且不同阶段（预热 / prefill / decode）
功耗不同。5 轮 × 42 秒的跑批会让 20 秒桶落在循环的不同相位上，
实测桶间 sd 可达 **500~1350 mW**，而 A−B 的差值只有百毫瓦级 —— 单次长跑分不开。

所以采用**配对交替**：A → 冷却 → B → 冷却 → …，同一对内部相减。
这样热漂移和时段漂移都会被抵消，同时每块只有 2~3 分钟，不会持续积热。

报告里会给配对数、均值、95% CI，并在 CI 跨过 0 时明确告警。

## 读数口径

```
SystemPowerIn   充电器输入功率（mW）
SystemVoltageIn 输入电压（mV）
SystemCurrentIn 输入电流（mA）     满足 SystemCurrentIn × SystemVoltageIn ≈ SystemPowerIn
BatteryPower    电池侧功率（mW）；**为负表示电池在补电**

整机功率 = SystemPowerIn - BatteryPower
```

设备接 15 W 口满载时会顶满，并由电池补电（实测可达 -2000 mW），
此时**必须加回电池那一段**，只看 `SystemPowerIn` 会低估。

## 必须先声明的边界

- 这是**整机功率**，包含屏幕、CPU、GPU、DRAM 与闪存，不是 GPU 单独功耗。
- GPU 与 SSD 的拆分依赖 **A/B 做差**，不是直接测量；差值归因给
  「SSD 搬运」（读盘 + 写 GPU 槽位），不是 NAND 器件自身能耗。
- 充电器容量会影响能否直接读绝对值；容量不足时依赖 `BatteryPower` 补算。
- `PowerTelemetryData` 的刷新粒度决定了**无法分辨短于 20 秒的事件**。
