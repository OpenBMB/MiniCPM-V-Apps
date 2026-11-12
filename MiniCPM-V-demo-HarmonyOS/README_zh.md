# MiniCPM-V Demo — HarmonyOS NEXT

[English (TODO)](README.md) | **中文**

本目录是 MiniCPM-V 端侧多模态 demo 的 **HarmonyOS NEXT 原生版本**，与 `MiniCPM-V-demo/`（iOS）和 `MiniCPM-V-demo-Android/`（Android）三端共享仓库根目录的 `llama.cpp-omni` 子模块。

---

## 1. 环境要求

* **DevEco Studio 5.0+**（带 Native SDK / NDK）
  下载：[https://developer.huawei.com/consumer/cn/deveco-studio/](https://developer.huawei.com/consumer/cn/deveco-studio/)
* HarmonyOS SDK API 12 以上（已在 `build-profile.json5` 中固定 `compatibleSdkVersion = 5.0.0(12)`，`targetSdkVersion = 5.0.5(17)`）
* CMake 由 ohos-ndk 自带，**不要**自己装系统级 CMake
* `arm64-v8a` 真机或模拟器，建议运行内存 ≥ 6 GB
* 华为开发者账号（自动签名时使用，**注册免费**）

参考机型：**华为 nova 14 活力版**（HarmonyOS 5.1）实测可跑。

---

## 2. 第一次打开工程

```bash
git clone https://github.com/OpenBMB/MiniCPM-V-Apps.git
cd MiniCPM-V-Apps
git submodule update --init --recursive
```

之后用 DevEco Studio：

1. `File` → `Open` 选 `MiniCPM-V-Apps/MiniCPM-V-demo-HarmonyOS/`
2. 等右下角 SDK / oh_modules 自动同步完成
3. `File` → `Project Structure` → `Signing Configs` → 勾 **Automatically generate signature**（首次会要求登录华为开发者账号）
4. 把真机连上 mac，开启开发者模式与 USB 调试，`hdc list targets` 能看到设备序列号即可
5. 点 `Run`（绿色三角），首次构建较慢（要把 `llama.cpp` + `ggml` + `mtmd` 整个编译一遍）

## 2.x 命令行打包（不开 IDE 也能跑）

`scripts/` 下三个脚本封装了所有 `NODE_HOME` / `JAVA_HOME` / `DEVECO_SDK_HOME` 的导出，
默认从 `/Applications/DevEco-Studio.app` 取工具链。

```bash
cd MiniCPM-V-demo-HarmonyOS

# 仅做命令行编译（无需登录华为账号），产物 = unsigned hap
./scripts/build_hap.sh           # 默认 debug，过 native + ArkTS + 资源 + PackageHap

# 编译 + 安装（首次需先在 IDE 里走一次 Automatically generate signature）
./scripts/build_hap.sh && ./scripts/install_hap.sh
```

> 命令行能走完 native CMake / ArkTS 编译 / 打包，但**真机安装必须经过华为后端签发的调试证书**——这个步骤目前只能通过 DevEco Studio 的"自动签名"完成（华为账号 + 5 分钟），签完之后签名材料会缓存在 `~/.ohos/config/auto_signing/`，后续命令行就能直接复用。

---

## 3. 模型文件

应用启动后，进入 **模型管理** 页面（右上角"模"按钮），首次点击 **下载模型** 即可：

* MiniCPM-V-4：HuggingFace 失败时自动回退到 ModelScope，`ggml-model-Q4_K_M.gguf` + `mmproj-model-f16.gguf`
* MiniCPM-V-4.6：直链 OBS（与 iOS demo 同源），自动 MD5 校验
* MiniCPM-OCR 1.0：三个文件（LLM + 4x `mmproj` + PP-DocLayoutV3 ONNX），HF / ModelScope 竞争下载，逐个 MD5 校验。`@ohos/onnxruntime` 需要 `@ohos/aki` 1.2.26（工程已用 `overrides` 锁定），版本不匹配会在原生侧 `SIGSEGV`

应用沙箱目录：`/data/storage/el2/base/files/models/<model_id>/`

> 沙箱路径受 SELinux 保护。实测在正式版本（非 root）下，`hdc file send` 和 `hdc shell` 写入
> `/data/app/el2/100/base/<bundle>/files/models/` 都会被拒绝（`Permission denied`），
> 应用读 `/data/local/tmp` 也会被拦。**请统一走应用内下载**，不要依赖侧载。

---

## 4. 工程结构

```
MiniCPM-V-demo-HarmonyOS/
├── AppScope/
│   ├── app.json5                      # 包名 com.tianchi.minicpmv
│   └── resources/                     # 应用级 icon
├── entry/
│   ├── build-profile.json5            # ABI: arm64-v8a，CMake 参数与 Android 对齐
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5               # INTERNET / GET_NETWORK_INFO / KEEP_BACKGROUND_RUNNING
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets    # 启动入口（生命周期）
│       │   ├── pages/
│       │   │   ├── Index.ets                    # 聊天主页（对应 MainActivity.kt）
│       │   │   ├── ModelManager.ets             # 模型管理页（对应 ModelManagerActivity.kt）
│       │   │   ├── TtsPage.ets                  # VoxCPM2 语音合成页
│       │   │   └── OcrPage.ets                  # MiniCPM-OCR 页面（对应 OcrActivity.kt）
│       │   ├── engine/
│       │   │   ├── LlamaEngine.ets              # 单例 + 状态机 + 串行队列 + 流式 token
│       │   │   ├── LlamaState.ets               # 状态机定义
│       │   │   └── ModelInfo.ets                # 模型清单（与 iOS/Android 严格同源）
│       │   ├── components/
│       │   │   ├── ChatMessageList.ets          # LazyForEach 数据源
│       │   │   ├── WelcomeCard.ets
│       │   │   ├── UserMessageItem.ets
│       │   │   └── AiMessageItem.ets
│       │   ├── data/ChatMessage.ets             # 消息数据类
│       │   ├── ocr/
│       │   │   ├── LayoutDetector.ets           # PP-DocLayoutV3 (onnxruntime)
│       │   │   ├── OcrLayout.ets                # 重叠过滤 + 邻居合并 + 裁剪
│       │   │   ├── OcrPrompts.ets               # 各版面元素的 prompt
│       │   │   ├── OcrMarkdown.ets              # OTSL 表格 / LaTeX 修复 / 拼装
│       │   │   └── OcrEngine.ets                # OCR 管线串联
│       │   └── utils/
│       │       ├── DownloadManager.ets          # HF/MS 探测 + OBS 直链 + MD5 校验
│       │       └── ImageCodec.ets               # 系统相册 + PNG 编码 → ArrayBuffer
│       ├── cpp/
│       │   ├── CMakeLists.txt                   # 复用仓库根 llama.cpp-omni
│       │   ├── napi_init.cpp                    # NAPI 模块注册
│       │   ├── llama_napi.cpp                   # 翻译自 llama_jni.cpp
│       │   ├── hilog_log.h                      # 替换 Android 的 logging.h
│       │   └── types/libentry/                  # ArkTS 类型声明
│       └── resources/                           # 字符串/颜色/main_pages.json
└── README_zh.md                                 # 本文件
```

---

## 5. 与 iOS / Android 的对齐点

| 维度 | iOS | Android | HarmonyOS |
|---|---|---|---|
| 推理参数 | `MTMDParams.swift` | `llama_jni.cpp` | `llama_napi.cpp` |
| `n_threads` | 4 | 4 | 4 |
| `n_ctx` / `n_batch` | 4096 / 2048 | 4096 / 2048 | 4096 / 2048 |
| 采样 | `temp=0.7, top_k=0, top_p=1.0` | 同 | 同 |
| `image_max_slice_nums` | 1 | 1 | 1 |
| 模型清单 | `MiniCPMModelConst.swift` | `ModelInfo.kt` | `ModelInfo.ets` |
| OBS 直链 / MD5 | 严格相同 | 严格相同 | 严格相同 |

---

## 6. 后续可选优化

* 把 `GGML_OPENMP` 打开（在 `entry/build-profile.json5` 改 `-DGGML_OPENMP=ON`），需要确认 ohos-ndk 的 OpenMP 运行时。
* 升级 KleidiAI 指令集到 `armv8.6-a+dotprod+i8mm+fp16+bf16`（与 Android 端一致）。当前 demo 默认 `armv8.2-a+dotprod+fp16` 以最大化兼容。

* 加深色模式资源 `resources/dark/`。

---

## 7. 故障排查

* **报 `llama.cpp-omni not found at ...`**：
  仓库根没有初始化子模块，回到根目录跑 `git submodule update --init --recursive`。
* **`libentry.so` 加载失败**：
  确认 `entry/oh-package.json5` 里的 `dependencies."libentry.so"` 路径与 `cpp/types/libentry/oh-package.json5` 的 `name` 字段一致。
* **真机 install 失败 / 9568 错误**：
  自动签名没配好，重新去 `Project Structure → Signing Configs` 勾一遍。
* **Run 时一直转圈**：
  首次构建要编整个 `llama.cpp + ggml + mtmd`，在 M 系列 mac 上约 5–10 分钟；后续增量编译只要数十秒。
