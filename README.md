# MiniCPM-V Demo — iOS, Android & HarmonyOS

**English** | [中文](README_zh.md)

This demo runs the MiniCPM-V family of multimodal models fully on-device on iOS, Android, and HarmonyOS NEXT. Currently supported:

* **MiniCPM-V 2.6**
* **MiniCPM-V 4.0**
* **MiniCPM-V 4.6**
* **MiniCPM-V 4.7 35B-A3B** (MoE, streams experts from SSD)
* **MiniCPM-V 4.7 1B** (dense)
* **MiniCPM5-1B** (text-only)
* **MiniCPM5-2B** (text-only)
* **VoxCPM2** (text-to-speech, TTS)

This repository contains three on-device demos for MiniCPM-V (multimodal LLM) running fully locally via `llama.cpp`:

* `MiniCPM-V-demo/` — iOS demo (Xcode project)
* `MiniCPM-V-demo-Android/` — Android demo (Gradle / Kotlin)
* `MiniCPM-V-demo-HarmonyOS/` — HarmonyOS NEXT demo (DevEco Studio / ArkTS)

All three demos share the same `llama.cpp-omni` submodule (branch `ios-omni`) at the repo root.

> **NOTE**: This project bundles `llama.cpp` as a git submodule. The upstream fork `tc-mb/llama.cpp-omni` carries a dozen unrelated branches and a full clone weighs ~350 MB, so `shallow = true` is set in `.gitmodules` by default. The recommended **shallow + single-branch** clone is:
>
> ```bash
> # one-shot (parent repo + submodules, all shallow)
> git clone --recurse-submodules --shallow-submodules \
>     https://github.com/OpenBMB/MiniCPM-V-Apps.git
> cd MiniCPM-V-Apps
> ```
>
> Or, if you've already cloned the parent repo and want to init the submodule afterwards:
>
> ```bash
> git submodule update --init --recursive --depth 1 --single-branch
> ```
>
> This only pulls a single commit of the `ios-omni` branch (~tens of MB) instead of the full llama.cpp-omni fork history. Developers who need to push to `tc-mb/llama.cpp-omni:ios-omni` can run `git fetch --unshallow` inside the submodule to lift the shallow restriction.

The README is organised in two parts:

* **Part 1 — Platform setup**: how to build and run the demo on iOS, Android and HarmonyOS.
* **Part 2 — GGUF model files**: where to get the model weights for each MiniCPM-V version, and the minimum on-device hardware needed to run them.

---

> **Just want to install the app?** Pre-built packages are below; step-by-step instructions (requirements, signing notes, MD5) are in **[DOWNLOAD.md](DOWNLOAD.md)**. The rest of this README is only needed if you want to build from source.

| Platform | Install |
| --- | --- |
| 🍎 **iOS / iPadOS** | [TestFlight — public link](https://testflight.apple.com/join/yNKyFZwW) |
| 🤖 **Android** | [APK — latest release](https://github.com/OpenBMB/MiniCPM-V-Apps/releases/latest) |
| 📱 **HarmonyOS** | [HAP — latest release](https://github.com/OpenBMB/MiniCPM-V-Apps/releases/latest) |

---

## Part 1. Platform Setup

### 1.1 iOS Demo

**NOTE: To deploy and test the app on an iOS device, you may need an Apple Developer account.**

#### 1.1.1 Install Xcode & command-line tools

* Download Xcode from the App Store (verified on Xcode 26.1.1; project deployment target = iOS 16.6)
* Install the Command Line Tools:

  ```bash
  xcode-select --install
  ```
* Agree to the software license agreement:

  ```bash
  sudo xcodebuild -license
  ```
* CMake ≥ 3.28 (needed by the xcframework build in the next step):

  ```bash
  brew install cmake
  ```

#### 1.1.2 Build llama.xcframework (required on first build)

This repo **does not track** any compiled artefacts, so the prebuilt `llama.xcframework` (~189 MB) needs to be produced locally from the `llama.cpp-omni` submodule and dropped into `MiniCPM-V-demo/thirdparty/` for Xcode to link against. A one-shot script is provided — by default it only builds the two slices the demo actually links (real device + simulator), which takes ~2-3 min on a modern M-series Mac:

```bash
./scripts/build_xcframework.sh
```

The output is installed at `MiniCPM-V-demo/thirdparty/llama.xcframework/`.

If you need a different build scope, the script forwards `MINIMAL_MODE`:

```bash
MINIMAL_MODE=ios-sim    ./scripts/build_xcframework.sh   # simulator only        (~3 min)
MINIMAL_MODE=ios-device ./scripts/build_xcframework.sh   # device only           (~3 min)
MINIMAL_MODE=ios        ./scripts/build_xcframework.sh   # device + simulator (default, ~3 min)
MINIMAL_MODE=macos      ./scripts/build_xcframework.sh   # macOS slice only      (not used by this demo)
```

> This demo only links the iOS slices (device + simulator), so the default is all you need. `macos` is a
> separate mode for the Mac-side CLI; `all` currently behaves identically to `ios` (same branch in the
> script), it is **not** a multi-platform build.

The script drives **cmake directly** against the `llama.cpp-omni` submodule (it modifies no file inside
it), then copies the resulting `llama.cpp-omni/build-apple/llama.xcframework` into
`MiniCPM-V-demo/thirdparty/`. There is **no** pre-existing build script inside the submodule — if you
need custom compile flags, read `scripts/build_xcframework.sh`.

During the build you will see warnings like `ignoring duplicate libraries` and `skipping debug map object with duplicate name and timestamp` — these come from llama.cpp's mtmd module having identically-named `.o` files across different model architectures. They are **harmless** and the resulting framework works correctly.

> **When do I need to rebuild?**
> - The parent repo bumped the llama.cpp-omni submodule pointer (`git submodule status` shows a commit different from your last local build).
> - You edited any source under `llama.cpp-omni/` that affects the framework.

#### 1.1.3 Download onnxruntime.xcframework (required on first build)

OCR layout detection links Microsoft ONNX Runtime. The repo does **not** track `onnxruntime.xcframework` (~44 MB zip / ~194 MB unpacked). Fetch the public `onnxruntime-c` 1.21.0 CocoaPods archive (iOS device + simulator + macOS slices) with:

```bash
./scripts/download_onnxruntime.sh
```

The script writes `MiniCPM-V-demo/thirdparty/onnxruntime.xcframework/` and skips the download if 1.21.0 is already present. Re-fetch with `FORCE=1 ./scripts/download_onnxruntime.sh`.

The archive URL is Microsoft's public host: `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.21.0.zip` (SHA-256 is pinned in the script). This Xcode project always links that framework, so the download is required even if you are not using OCR.

#### 1.1.4 Open in Xcode and run

Open `MiniCPM-V-demo.xcodeproj` at the **repository root** (it is not under the `MiniCPM-V-demo/` subdirectory). It may take a moment for Xcode to automatically download the required dependencies.

1. **Switch to your own signing team.** Select the `MiniCPM-V-demo` target → `Signing & Capabilities`
   and change `Team` to your own account. The repo ships with the author's Team ID, so building without
   changing it fails to sign.
2. **Enable Developer Mode on the device.** Required on iOS / iPadOS 16 and later, otherwise
   installation is rejected: `Settings → Privacy & Security → Developer Mode`.
3. Select the target device at the top, then click the "Run" (triangle) button to launch the demo.
4. On first launch, go to **Settings → Model Management**, tap **Download All** for the model you want,
   then **Use This Model** to activate it. See §2.4 for the files and their on-device locations.

If Xcode fails with `There is no XCFramework found at '.../llama.xcframework'`, you skipped §1.1.2 — go back and run the build. If the missing path is `onnxruntime.xcframework`, you skipped §1.1.3.

### 1.2 Android Demo

Requirements:

* Android Studio (Giraffe or newer)
* Android SDK + NDK (the project pins NDK `27.0.12077973` and CMake `3.22.1`)
* A physical device with a 64-bit ARM SoC (`arm64-v8a`)
* Device RAM: see the per-model requirements in [Part 2](#part-2-gguf-model-files)

Build & run:

```bash
cd MiniCPM-V-demo-Android
./gradlew assembleDebug
```

Or open `MiniCPM-V-demo-Android/` directly in Android Studio and click Run.

The first launch will download the GGUF model files into the app's external storage. You can also sideload model files manually via `adb push` — see in-app **Model Manager** for the expected directory layout.

### 1.3 HarmonyOS Demo

Requirements:

* DevEco Studio 5.0 or newer (with the HarmonyOS Native SDK / NDK)
* A real device or emulator running HarmonyOS API 12+ (e.g. nova 14 vitality / Mate 60 / Pura 70)
* 64-bit ARM architecture (`arm64-v8a`)
* Device RAM: see the per-model requirements in [Part 2](#part-2-gguf-model-files)

Build & run:

1. Open `MiniCPM-V-demo-HarmonyOS/` in DevEco Studio.
2. `File` → `Project Structure` → `Signing Configs` and tick **Automatically generate signature** (requires a Huawei developer account; this only needs to be done once).
3. Connect the device with USB debugging enabled, then click Run (the green triangle).

After the first launch, open the in-app **Model Manager** and tap **Download**. You can also sideload model files via `hdc file send`; see `MiniCPM-V-demo-HarmonyOS/README_zh.md` for the expected directory layout.

> The HarmonyOS port shares the exact same `llama.cpp-omni` submodule, model catalogue, OBS direct-link URLs and MD5 hashes with the iOS / Android demos.

---

## Part 2. GGUF Model Files

### Hardware requirements

The on-device memory needed to run a model is roughly *(model file size) + KV cache + a few hundred MB of working memory for the vision encoder and llama.cpp internals*. The recommended values below leave enough headroom for the OS and the demo app itself.

| Model | LLM params | Recommended quant | LLM file | mmproj (f16) | Total download | Recommended device RAM |
| --- | --- | --- | --- | --- | --- | --- |
| MiniCPM-V 2.6 | 8B | Q4_K_M | ~4.4 GB | ~1.0 GB | ~5.4 GB | **≥ 8 GB** |
| MiniCPM-V 4.0 | 4.1B | Q4_K_M | ~2.0 GB | ~0.9 GB | ~2.9 GB | **≥ 6 GB** |
| MiniCPM-V 4.6 | 1.3B | Q4_K_M | ~0.5 GB | ~1.1 GB | ~1.6 GB | **≥ 6 GB** |
| MiniCPM-V 4.7 35B-A3B | 35B (3B active) | q3gud-im (Q3_K experts) | ~1.7 GB | ~1.1 GB | **~16.6 GB** | **≥ 12 GB** |
| MiniCPM-V 4.7 1B | 1B | Q4_K_M | ~0.7 GB | ~1.1 GB | ~1.8 GB | **≥ 4 GB** |
| MiniCPM5-1B | 1B | Q4_K_M | ~0.5 GB | — | ~0.5 GB | **≥ 4 GB** |
| MiniCPM5-2B | 2B | Q4_K_M | ~1.5 GB | — | ~1.5 GB | **≥ 6 GB** |
| VoxCPM2 (TTS) | ~2B | Q4_K_M + F16 | ~1.0 GB | — | ~2.8 GB | **≥ 6 GB** |

Notes:

* `mmproj` is the vision projector + ViT weights; it is shipped in **f16** because quantising the visual tower hurts perception quality noticeably more than quantising the LLM.
* MiniCPM5-1B and MiniCPM5-2B are text-only models and do not need an `mmproj` file.
* VoxCPM2 requires two GGUF files (BaseLM + Acoustic) and does not use an `mmproj` either — it is a pure TTS model.
* MiniCPM-V 4.7 35B-A3B uses a **Q3_K** expert quant (`mix_q3gud_im`) rather than Q4, and its routed experts are split out of the main `.gguf` into a separate `experts/` directory. The **~16.6 GB** above is the main file + all 40 expert shards + `mmproj`; plan for ~17 GB of free storage. Because the experts are streamed from SSD on demand rather than held in RAM, this variant also needs **fast internal storage** — see §2.4.
* All three demos default to a context window of 4K tokens. Larger contexts will increase the KV-cache footprint roughly linearly, so on a borderline device you may need to lower it.
* On Android / HarmonyOS, devices with 8 GB+ RAM are strongly recommended for V 2.6. On iOS, V 2.6 has been validated on iPhone 15 Pro / 16 series and recent iPads with M-series chips; older 6 GB devices may swap heavily.
* MiniCPM-V 4.7 35B-A3B has been validated on a 12 GB iPhone 17 Pro Max. On devices with less RAM the app automatically falls back to a **smaller expert cache**, which works but is considerably slower.

### 2.1 MiniCPM-V 2.6 GGUF Files

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf](https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-2_6-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-2_6-gguf)

Download the language model file (e.g., `ggml-model-Q4_0.gguf`) and the vision model file (`mmproj-model-f16.gguf`) from the repository.

### 2.2 MiniCPM-V 4.0 GGUF Files

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-4-gguf](https://huggingface.co/openbmb/MiniCPM-V-4-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-4-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-4-gguf)

Download the language model file (e.g., `ggml-model-Q4_K_M.gguf`) and the vision model file (`mmproj-model-f16.gguf`) from the repository.

### 2.3 MiniCPM-V 4.6 GGUF Files

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.6-gguf](https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.6-gguf)

Download the language model file (e.g., `MiniCPM-V-4_6-Q4_K_M.gguf`) and the vision model file (`mmproj-model-f16.gguf`) from the repository.

### 2.4 MiniCPM-V 4.7 GGUF Files

MiniCPM-V 4.7 ships in two sizes:

* **MiniCPM-V 4.7 35B-A3B** — MoE (35B total / 3B active). Uses **MoE-SSD**: the routed experts are
  stripped out of the main `.gguf` into a separate `experts/` directory and streamed from SSD on
  demand, which is what makes a 35B-class model runnable on a phone.
* **MiniCPM-V 4.7 1B** — dense, small enough to keep everything resident.

#### Where to get the GGUF files

There are **two** sets, for two different purposes:

* **Standard quants — desktop / server.** The official repos carry the usual whole-model quant range
  (F16, Q4_K_M, Q5_K_M, Q6_K, Q8_0, …). Pick whichever fits your machine's memory.

  * HuggingFace: [openbmb/MiniCPM-V-4.7-35B-A3B-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf) · [openbmb/MiniCPM-V-4.7-1B-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf)
  * ModelScope: [openbmb/MiniCPM-V-4.7-35B-A3B-gguf](https://modelscope.cn/models/openbmb/MiniCPM-V-4.7-35B-A3B-gguf) · [openbmb/MiniCPM-V-4.7-1B-gguf](https://modelscope.cn/models/openbmb/MiniCPM-V-4.7-1B-gguf)

* **On-device split — for this demo, on a phone.** The `-les` main file plus its `experts/` directory
  (and the 1B revision this demo is actually built and tested against).

  * HuggingFace: [tc-mb/MiniCPM-V-Apps-gguf](https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf)
  * ModelScope: [zerg13/MiniCPM-V-Apps-gguf](https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf)

> **Why a separate split exists.** The official repos do **not** carry a `-les` variant, and this demo
> cannot load their 35B `mix_q3gud_im.gguf`: that file keeps the routed experts inline, so a phone would
> need the whole ~15.5 GB as a single Metal buffer (mmap) or as resident memory (no-mmap) — either way
> the OS kills it. Stripping the experts into `experts/` lets them be paged in from SSD on demand, which
> is what makes 35B-class inference possible on a phone at all. The split is therefore an artifact made
> *for* this demo, not a general-purpose release. 1B needs no split; it is hosted above only because
> that is the revision this demo was validated against.

Files are grouped into per-model sub-directories:

| Variant | Files | On-device location |
| --- | --- | --- |
| **35B-A3B** | `MiniCPM-V-4.7-35B-A3B/MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf`<br>`MiniCPM-V-4.7-35B-A3B/mmproj-model-f16.gguf`<br>`MiniCPM-V-4.7-35B-A3B/experts/` (40 shards + `manifest.json`) | `Documents/MiniCPMV47/` |
| **1B** | `MiniCPM-V-4.7-1B/MiniCPM-V-4_7-1B-Q4_K_M.gguf`<br>`MiniCPM-V-4.7-1B/mmproj-model-f16.gguf` | `Documents/MiniCPMV47_1B/` |

> **The `experts/` directory must stay together with its main file.** The `-les` variant carries no
> routed-expert weights of its own, so a mismatched pair fails the on-disk consistency check and the
> model refuses to load. The reliable way to get this right is to download **inside the app**
> (Settings → tap the model → **Download**), which fetches every file and verifies the shard sizes
> for you.

### 2.5 MiniCPM5-1B GGUF Files (text-only)

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM5-1B-GGUF](https://huggingface.co/openbmb/MiniCPM5-1B-GGUF)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF](https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF)

Download the language model file (e.g., `MiniCPM5-1B-Q4_K_M.gguf`) from the repository. MiniCPM5 is text-only, so no `mmproj` is required.

### 2.6 MiniCPM5-2B GGUF Files (text-only)

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/openbmb/MiniCPM5-2B-GGUF](https://huggingface.co/openbmb/MiniCPM5-2B-GGUF)
* ModelScope: [https://modelscope.cn/models/OpenBMB/MiniCPM5-2B-GGUF](https://modelscope.cn/models/OpenBMB/MiniCPM5-2B-GGUF)

Download the language model file (e.g., `MiniCPM5-2B-Q4_K_M.gguf`) from the repository. MiniCPM5 is text-only, so no `mmproj` is required.

### 2.7 VoxCPM2 GGUF Files (text-to-speech)

VoxCPM2 is a ~2B-parameter text-to-speech model. It consists of two GGUF files:

- **BaseLM** (`VoxCPM2-BaseLM-Q4_K_M.gguf`, ~956 MB) — the MiniCPM-4 based language model
- **Acoustic** (`VoxCPM2-Acoustic-F16.gguf`, ~1.74 GB) — the acoustic decoder (FSQ + LocEnc + LocDiT + AudioVAE)

VoxCPM2 supports 30+ languages and 9 Chinese dialects. It can generate speech from text directly (voice-design mode) or clone a voice from a reference audio clip.

#### Download Official GGUF Files

* HuggingFace: [https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf](https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf)
* ModelScope: [https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf](https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf)

After downloading, place both `.gguf` files in the app's **Documents** directory (iOS) or in the per-model folder under `{ExternalFilesDir}/models/` (Android / HarmonyOS). You can also download them directly inside the app via **Model Manager**. Once models are downloaded, select VoxCPM2 and the app switches to the TTS interface automatically.
