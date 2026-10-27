# MiniCPM-V Demo — iOS、Android 与 HarmonyOS

[English](README.md) | **中文**

本项目演示了 MiniCPM-V 系列多模态模型在 iOS、Android 与 HarmonyOS NEXT 设备上的端侧本地推理。当前已支持：

* **MiniCPM-V 2.6**
* **MiniCPM-V 4.0**
* **MiniCPM-V 4.6**
* **MiniCPM-V 4.7 35B-A3B**（MoE，专家权重从 SSD 流式读取）
* **MiniCPM-V 4.7 1B**（dense）
* **MiniCPM5-1B**（纯文本）
* **MiniCPM5-2B**（纯文本）
* **VoxCPM2**（语音合成 TTS）

仓库中包含三份基于 `llama.cpp` 完整本地推理的 demo：

* `MiniCPM-V-demo/` — iOS demo（Xcode 工程）
* `MiniCPM-V-demo-Android/` — Android demo（Gradle / Kotlin）
* `MiniCPM-V-demo-HarmonyOS/` — HarmonyOS NEXT demo（DevEco Studio / ArkTS）

三端共享仓库根目录的同一份 `llama.cpp-omni` 子模块。

> **提示**：本项目通过 git submodule 引入 `llama.cpp`。子模块上游 `tc-mb/llama.cpp-omni` 还有十几个无关分支，全量 clone 要拉 ~350 MB，所以 `.gitmodules` 里默认 `shallow = true`。推荐用如下 **shallow + single-branch** 方式 clone：
>
> ```bash
> # 一步到位（父仓库 + 子模块都浅 clone）
> git clone --recurse-submodules --shallow-submodules \
>     https://github.com/OpenBMB/MiniCPM-V-Apps.git
> cd MiniCPM-V-Apps
> ```
>
> 如果你已经 clone 了父仓库再 init 子模块：
>
> ```bash
> git submodule update --init --recursive --depth 1 --single-branch
> ```
>
> 这样只会拉 `ios-omni` 分支的单 commit（约几十 MB），不会拉整个 llama.cpp-omni fork 的全 history。需要 push 到 `tc-mb/llama.cpp-omni:ios-omni` 的开发者可在 submodule 里执行 `git fetch --unshallow` 取消浅 clone。

README 分为两大部分：

* **第一部分 — 平台安装与构建**：iOS / Android / HarmonyOS 三端如何编译运行。
* **第二部分 — GGUF 模型文件**：支持的模型权重下载方式，以及对应的最小端侧硬件要求。

---

> **只想安装 App？** 预编译安装包见下表；详细步骤（要求、签名说明、MD5）在 **[DOWNLOAD_zh.md](DOWNLOAD_zh.md)**。下面的内容只在你打算从源码自行构建时才需要。

| 平台 | 安装 |
| --- | --- |
| 🍎 **iOS / iPadOS** | [TestFlight — 公开链接](https://testflight.apple.com/join/yNKyFZwW) |
| 🤖 **Android** | [APK — 最新 release](https://github.com/OpenBMB/MiniCPM-V-Apps/releases/latest) |
| 📱 **HarmonyOS** | [HAP — 最新 release](https://github.com/OpenBMB/MiniCPM-V-Apps/releases/latest) |

---

## 第一部分　平台安装与构建

### 1.1 iOS Demo

**注意：在 iOS 设备上部署和测试 demo，可能需要 Apple Developer 账号。**

#### 1.1.1 安装 Xcode 与命令行工具

* 在 App Store 下载 Xcode（已在 Xcode 26.1.1 上验证；项目 deployment target = iOS 16.6）
* 安装 Command Line Tools：

  ```bash
  xcode-select --install
  ```
* 同意软件许可协议：

  ```bash
  sudo xcodebuild -license
  ```
* CMake ≥ 3.28（下一步 build xcframework 需要）：

  ```bash
  brew install cmake
  ```

#### 1.1.2 首次构建 llama.xcframework（必做）

仓库**不追踪**任何编译产物，预编译的 `llama.xcframework`（~189 MB）需要你在本地从 `llama.cpp-omni` 子模块编译一份，放到 `MiniCPM-V-demo/thirdparty/` 让 Xcode 链接。我们提供了一键脚本，默认只 build demo 真正用到的两个 slice（真机 + 模拟器），M 系 Mac 上 ~2-3 分钟：

```bash
./scripts/build_xcframework.sh
```

完成后产物落在 `MiniCPM-V-demo/thirdparty/llama.xcframework/`。

如果你想自己控制 build 范围，脚本通过 `MINIMAL_MODE` 环境变量切换：

```bash
MINIMAL_MODE=ios-sim    ./scripts/build_xcframework.sh   # 只模拟器 (~3 min)
MINIMAL_MODE=ios-device ./scripts/build_xcframework.sh   # 只真机   (~3 min)
MINIMAL_MODE=ios        ./scripts/build_xcframework.sh   # 真机+模拟器（默认，~3 min）
MINIMAL_MODE=macos      ./scripts/build_xcframework.sh   # 只 macOS 切片（本 demo 用不到）
```

> 本 demo 只链接 iOS 切片（真机 + 模拟器），上面默认档就够了。`macos` 是给 Mac 侧 CLI 用的
> 独立档位；`all` 目前与 `ios` 等价（脚本里走同一分支），不是「全平台」。

脚本内部**直接调 cmake** 编译 `llama.cpp-omni` 子模块（不修改子模块里任何文件），再把产物
`llama.cpp-omni/build-apple/llama.xcframework` 复制到 `MiniCPM-V-demo/thirdparty/`。子模块里
**没有**现成的构建脚本，需要自定义编译参数时请直接读 `scripts/build_xcframework.sh`。

Build 过程中会出现 `ignoring duplicate libraries` 和 `skipping debug map object with duplicate name and timestamp` 的 warning —— 这是 llama.cpp 上游 mtmd 模块在不同 model arch 下同名 `.o` 的去重提示，**无害**，产物正常。

> **什么时候要重 build？**
> - 父仓库 bump 了 llama.cpp-omni submodule 指针（`git submodule status` 显示与本地构建时不同的 commit）
> - 你自己改动了 `llama.cpp-omni/` 下任意源码

#### 1.1.3 下载 onnxruntime.xcframework（首次构建必做）

OCR 版面检测依赖微软 ONNX Runtime。仓库**不追踪** `onnxruntime.xcframework`（zip 约 44 MB，解压约 194 MB）。用下面的脚本拉取公开的 `onnxruntime-c` 1.21.0 CocoaPods 归档（含真机 + 模拟器 + macOS slice）：

```bash
./scripts/download_onnxruntime.sh
```

产物落在 `MiniCPM-V-demo/thirdparty/onnxruntime.xcframework/`。若本地已是 1.21.0 则跳过下载；需要重下时：`FORCE=1 ./scripts/download_onnxruntime.sh`。

归档地址是微软公开源：`https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.21.0.zip`（SHA-256 写在脚本里）。当前 Xcode 工程始终链接该 framework，即使不跑 OCR 也要先下。

#### 1.1.4 用 Xcode 打开并运行

用 Xcode 打开**仓库根目录**的 `MiniCPM-V-demo.xcodeproj`（不在 `MiniCPM-V-demo/` 子目录里），等待 Xcode 自动下载所需依赖。

1. **换成你自己的签名团队。** 选中 `MiniCPM-V-demo` target → `Signing & Capabilities`，把
   `Team` 改成你自己的账号。仓库里带的是作者的 Team ID，不改会直接签名失败。
2. **在设备上开启开发者模式。** iOS / iPadOS 16 及以上必须先手动打开，否则装不上：
   `设置 → 隐私与安全性 → 开发者模式`。
3. 顶部选择目标设备，点击 "Run"（三角形）按钮启动 demo。
4. 首次启动后进入 **设置 → 模型管理**，选目标模型点 **一键下载**，下载完点 **使用此模型**
   激活。模型文件与落盘路径见 §2.4。

如果 build 报 `There is no XCFramework found at '.../llama.xcframework'`，说明你跳过了 §1.1.2，回到上一步执行 build。如果缺的是 `onnxruntime.xcframework`，说明跳过了 §1.1.3。

### 1.2 Android Demo

环境要求：

* Android Studio（Giraffe 或更新版本）
* Android SDK + NDK（项目固定 NDK `27.0.12077973`、CMake `3.22.1`）
* 64 位 ARM 架构（`arm64-v8a`）的真机
* 设备内存：参见[第二部分](#第二部分gguf-模型文件)中按模型给出的内存要求

构建并运行：

```bash
cd MiniCPM-V-demo-Android
./gradlew assembleDebug
```

或直接用 Android Studio 打开 `MiniCPM-V-demo-Android/` 目录，点击 Run。

首次启动时，应用会自动把 GGUF 模型文件下载到外部存储。也可以通过 `adb push` 手动侧载模型文件——具体目录结构请参考 App 内的 **模型管理** 页面。

### 1.3 HarmonyOS Demo

环境要求：

* DevEco Studio 5.0 或更新版本（含 Native SDK / NDK）
* HarmonyOS API 12 及以上的真机或模拟器（如 nova 14 活力版 / Mate 60 / Pura 70 等）
* 64 位 ARM 架构（`arm64-v8a`）
* 设备内存：参见[第二部分](#第二部分gguf-模型文件)中按模型给出的内存要求

构建并运行：

1. 在 DevEco Studio 中打开 `MiniCPM-V-demo-HarmonyOS/` 目录
2. `File` → `Project Structure` → `Signing Configs` 勾选 **Automatically generate signature**
3. 真机连接后开启开发者模式与 USB 调试，点击 Run（绿色三角）

首次启动后，进入应用内的 **模型管理** 页面点击 **下载模型**。也可以使用 `hdc file send` 旁路侧载模型文件，详见 `MiniCPM-V-demo-HarmonyOS/README_zh.md`。

> 鸿蒙端 C++ 推理层与 Android、iOS 共用仓库根目录的 `llama.cpp-omni` 子模块，模型清单 / OBS 直链 / MD5 哈希严格同源。

---

## 第二部分　GGUF 模型文件

### 硬件要求

端侧推理所需的内存大约等于 *模型权重大小 + KV cache + 视觉编码器与 llama.cpp 的若干百兆运行时开销*。下表给出的"推荐设备内存"已经为操作系统和 demo 应用本身预留了余量。

| 模型 | LLM 参数量 | 推荐量化 | LLM 文件 | mmproj（f16） | 总下载量 | 推荐设备内存 |
| --- | --- | --- | --- | --- | --- | --- |
| MiniCPM-V 2.6 | 8B | Q4_K_M | ~4.4 GB | ~1.0 GB | ~5.4 GB | **≥ 8 GB** |
| MiniCPM-V 4.0 | 4.1B | Q4_K_M | ~2.0 GB | ~0.9 GB | ~2.9 GB | **≥ 6 GB** |
| MiniCPM-V 4.6 | 1.3B | Q4_K_M | ~0.5 GB | ~1.1 GB | ~1.6 GB | **≥ 6 GB** |
| MiniCPM-V 4.7 35B-A3B | 35B（激活 3B） | q3gud-im（专家 Q3_K） | ~1.7 GB | ~1.1 GB | **~16.6 GB** | **≥ 12 GB** |
| MiniCPM-V 4.7 1B | 1B | Q4_K_M | ~0.7 GB | ~1.1 GB | ~1.8 GB | **≥ 4 GB** |
| MiniCPM5-1B | 1B | Q4_K_M | ~0.5 GB | — | ~0.5 GB | **≥ 4 GB** |
| MiniCPM5-2B | 2B | Q4_K_M | ~1.5 GB | — | ~1.5 GB | **≥ 6 GB** |
| VoxCPM2 (TTS) | ~2B | Q4_K_M + F16 | ~1.0 GB | — | ~2.8 GB | **≥ 6 GB** |

补充说明：

* `mmproj` 是视觉投影器 + ViT 权重，统一保留 **f16** 精度——视觉塔做低比特量化对感知质量的伤害比 LLM 更明显。
* MiniCPM5-1B 与 MiniCPM5-2B 为纯文本模型，不需要 `mmproj` 文件。
* VoxCPM2 需要两个 GGUF 文件（BaseLM + Acoustic），同样不需要 `mmproj`——它是一个纯语音合成模型。
* MiniCPM-V 4.7 35B-A3B 的专家权重用的是 **Q3_K** 量化（`mix_q3gud_im`）而非 Q4，且路由专家已从主 `.gguf` 中剥离到独立的 `experts/` 目录。表中的 **~16.6 GB** = 主文件 + 40 个专家分片 + `mmproj`，请预留约 17 GB 空闲存储。由于专家是按需从 SSD 流式读取、并不常驻内存，这一档还要求**较快的机身存储**，详见 §2.4。
* 三端 demo 默认上下文长度为 4K token。上下文越长，KV cache 占用近似线性增长，临界设备上可能需要相应调小。
* Android / HarmonyOS 上跑 V 2.6 强烈建议 8 GB 及以上内存。iOS 上 V 2.6 已在 iPhone 15 Pro / 16 系列以及搭载 M 系列芯片的较新 iPad 上验证；早期 6 GB 内存设备容易出现频繁换页。
* MiniCPM-V 4.7 35B-A3B 已在 12 GB 的 iPhone 17 Pro Max 上验证。内存更小的设备会自动退化为**更小的专家缓存**，仍可运行，但速度明显下降。

### 2.1 MiniCPM-V 2.6 GGUF 模型文件

#### 下载官方 GGUF 文件

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf](https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-2_6-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-2_6-gguf)

请从仓库下载语言模型文件（例如 `ggml-model-Q4_0.gguf`）以及视觉模型文件（`mmproj-model-f16.gguf`）。

### 2.2 MiniCPM-V 4.0 GGUF 模型文件

#### 下载官方 GGUF 文件

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-4-gguf](https://huggingface.co/openbmb/MiniCPM-V-4-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-4-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-4-gguf)

请从仓库下载语言模型文件（例如 `ggml-model-Q4_K_M.gguf`）以及视觉模型文件（`mmproj-model-f16.gguf`）。

### 2.3 MiniCPM-V 4.6 GGUF 模型文件

#### 下载官方 GGUF 文件

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.6-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.6-gguf)

请从仓库下载语言模型文件（例如 `MiniCPM-V-4_6-Q4_K_M.gguf`）以及视觉模型文件（`mmproj-model-f16.gguf`）。

### 2.4 MiniCPM-V 4.7 GGUF 模型文件

MiniCPM-V 4.7 有两个规格：

* **MiniCPM-V 4.7 35B-A3B** —— MoE（总参 35B / 激活 3B）。采用 **MoE-SSD**：路由专家权重已从主
  `.gguf` 中剥离到独立的 `experts/` 目录，按需从 SSD 流式读取——这正是 35B 级模型能在手机上跑起来的原因。
* **MiniCPM-V 4.7 1B** —— dense，体积小到可以全部常驻内存。

#### 从哪里获取 GGUF 文件

有**两套**文件，用途不同：

* **标准量化 —— 桌面 / 服务端。** 官方仓库提供完整的常规划化档位（F16、Q4_K_M、Q5_K_M、Q6_K、
  Q8_0 等），按自己机器的内存挑一档即可。

  * HuggingFace: [openbmb/MiniCPM-V-4.7-35B-A3B-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf) · [openbmb/MiniCPM-V-4.7-1B-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf)
  * ModelScope: [openbmb/MiniCPM-V-4.7-35B-A3B-gguf](https://modelscope.cn/models/openbmb/MiniCPM-V-4.7-35B-A3B-gguf) · [openbmb/MiniCPM-V-4.7-1B-gguf](https://modelscope.cn/models/openbmb/MiniCPM-V-4.7-1B-gguf)

* **端上拆分版 —— 供本 demo 在手机上使用。** `-les` 主文件 + 配套的 `experts/` 目录（以及本
  demo 实际构建与验证所用的那一版 1B）。

  * HuggingFace: [tc-mb/MiniCPM-V-Apps-gguf](https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf)
  * ModelScope: [zerg13/MiniCPM-V-Apps-gguf](https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf)

> **为什么需要单独一份拆分版。** 官方仓库**没有** `-les` 变体，而本 demo **无法**加载它们的 35B
> `mix_q3gud_im.gguf`：那个文件的专家权重是内联的，手机要么把整个 ~15.5 GB 当成一个 Metal buffer
> （mmap），要么全部常驻内存（关 mmap）—— 两种都会被系统杀掉。把专家剥离到 `experts/` 之后，它们
> 可以按需从 SSD 分页读入，这才是 35B 级模型能在手机上跑起来的前提。所以拆分版是**为本 demo 专门
> 制作**的产物，不是通用发布格式。1B 不需要拆分；把它一并放在上面，只是因为本 demo 是针对那一版
> 做的验证。

文件按模型分子目录存放：

| 规格 | 需要下载的文件 | 端上落盘位置 |
| --- | --- | --- |
| **35B-A3B** | `MiniCPM-V-4.7-35B-A3B/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf`<br>`MiniCPM-V-4.7-35B-A3B/mmproj-model-f16.gguf`<br>`MiniCPM-V-4.7-35B-A3B/experts/`（40 个分片 + `manifest.json`） | `Documents/MiniCPMV47/` |
| **1B** | `MiniCPM-V-4.7-1B/MiniCPM-V-4_7-1B-Q4_K_M.gguf`<br>`MiniCPM-V-4.7-1B/mmproj-model-f16.gguf` | `Documents/MiniCPMV47_1B/` |

> **`experts/` 目录必须和它的主文件配套使用。** `-les` 变体自身不含路由专家权重，两者批次不一致会
> 通不过端上的完整性校验，模型直接拒绝加载。最稳妥的做法是**直接用 App 内下载**（设置 → 点该模型
> → **下载**），它会拉取全部文件并逐个校验分片大小。

### 2.5 MiniCPM5-1B GGUF 模型文件（纯文本）

#### 下载官方 GGUF 文件

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM5-1B-GGUF](https://huggingface.co/openbmb/MiniCPM5-1B-GGUF)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF](https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF)

请从仓库下载语言模型文件（例如 `MiniCPM5-1B-Q4_K_M.gguf`）。MiniCPM5 为纯文本模型，不需要 `mmproj`。

### 2.6 MiniCPM5-2B GGUF 模型文件（纯文本）

#### 下载官方 GGUF 文件

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM5-2B-GGUF](https://huggingface.co/openbmb/MiniCPM5-2B-GGUF)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM5-2B-GGUF](https://modelscope.cn/models/OpenBMB/MiniCPM5-2B-GGUF)

请从仓库下载语言模型文件（例如 `MiniCPM5-2B-Q4_K_M.gguf`）。MiniCPM5 为纯文本模型，不需要 `mmproj`。

### 2.7 VoxCPM2 GGUF 模型文件（语音合成）

VoxCPM2 是约 2B 参数的语音合成模型，由两个 GGUF 文件组成：

- **BaseLM**（`VoxCPM2-BaseLM-Q4_K_M.gguf`，约 956 MB）—— 基于 MiniCPM-4 的语言模型
- **Acoustic**（`VoxCPM2-Acoustic-F16.gguf`，约 1.74 GB）—— 声学解码器（FSQ + LocEnc + LocDiT + AudioVAE 等）

VoxCPM2 支持 30+ 种语言和 9 种中国方言。可直接从文本生成语音（语音设计模式），也可通过参考音频进行声音克隆。

#### 下载 GGUF 模型文件

* HuggingFace: [https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf](https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf)
* ModelScope: [https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf](https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf)

下载后将两个 `.gguf` 文件放入 App 的 **Documents** 目录（iOS），或放入 `/models/{model_id}/` 目录（Android / HarmonyOS）。也可以在 App 内的 **模型管理** 页面直接下载。下载完成后选择 VoxCPM2 模型，App 将自动切换至语音合成界面。
