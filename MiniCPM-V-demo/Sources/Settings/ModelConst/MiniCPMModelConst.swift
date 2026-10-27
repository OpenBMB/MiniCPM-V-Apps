//
//  MiniCPMModelConst.swift
//  MiniCPM-V-demo
//
//  Created by Alex on 2024/6/17.
//

import Foundation

/// 定义 MiniCPM 模型常量
struct MiniCPMModelConst {
    
    // MARK: - Q4_K_M 2.6 多模态主模型
    
    /// MiniCPM 多模态-主模型 Q4_K_M 文件名
    static let modelQ4_K_MFileName = "MiniCPM-V-2_6-Q4_0.gguf"
    
    /// MiniCPM 多模态-主模型 Q4_K_M oss 下载地址
    static let modelQ4_K_MURLString = "https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf/resolve/main/ggml-model-Q4_0.gguf"
    
    /// 显示在 UI 上名字-Q4_K_M
    static let modelQ4_K_MDisplayedName = "MiniCPM-V 2.6 8B LLM INT4"
    
    /// Q4_K_M gguf 文件 md5 值
    static let modelQ4_K_MMD5 = "2d6497c0ef0957af80a5d6b69e0de89b"
    
    
    // MARK: - 2.6 mmproj VIT 模型
    
    /// MiniCPM 多模态-mmproj 模型 文件名
    static let mmprojFileName = "mmproj-model-f16.gguf"
    
    /// MiniCPM 多模态-mmproj 模型 NAS 下载地址
    static let mmprojURLString = "https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf/resolve/main/mmproj-model-f16.gguf"
    
    /// 显示在 UI 上名字-mmproj
    static let modelMMProjDisplayedName = "MiniCPM-V 2.6 8B VPM"
    
    /// mmproj gguf 文件 md5 值
    static let modelMMProjMD5 = "b539e887cc2b598f560465be65802b1b"
    
    
    // MARK: - 2.6 ANE 利用模块
    
    /// ANE 利用压缩包 文件名
    static let mlmodelcZipFileName = "ane_minicpmv26_f32.mlmodelc.zip"
    
    /// ANE 模型压缩包下载地址
    static let mlmodelcZipFileURLString = "https://huggingface.co/openbmb/MiniCPM-V-2_6-gguf/resolve/main/ane_minicpmv26_f32.mlmodelc.zip"
    
    /// ANE 利用显示在设置页的名称
    static let mlmodelcZipFileDisplayedName = "MiniCPM-V 2.6 8B ANE"
    
    /// ANE 利用压缩包 md5
    static let mlmodelcZipFileMD5 = "ddf77e6d274259dbcb35cd9e5ca26d1a"
    
    
    
    // MARK: - mbv4 多模态语言模型
    
    /// MiniCPM 多模态-主模型 Q4_K_M 文件名
    static let modelv4_Q4_K_M_FileName = "MiniCPM-V-4_0-Q4_0.gguf"
    
    /// MiniCPM 多模态-主模型 Q4_K_M oss 下载地址
    static let modelv4_Q4_K_M_URLString = "https://huggingface.co/openbmb/MiniCPM-V-4-gguf/resolve/main/ggml-model-Q4_0.gguf"

    static let modelv4_Q4_K_M_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4-gguf/repo?Revision=master&FilePath=ggml-model-Q4_0.gguf"
    
    /// 显示在 UI 上名字-Q4_K_M
    static let modelv4_Q4_K_M_DisplayedName = "MiniCPM-V 4.0 4B LLM INT4"
    
    /// Q4_K_M gguf 文件 md5 值
    static let modelv4_Q4_K_M_MD5 = "8fc4cc88e5ea73472ae795b57a0e7fdd"

    /// V2.6 / V4.0 旧版本共用的落盘文件名。升级时按 MD5 迁移到对应独立文件名。
    static let legacySharedModelFileName = "ggml-model-Q4_0.gguf"
    
    
    // MARK: - mbv4 mmproj VIT 模型
    
    /// MiniCPM 多模态-mmproj 模型 文件名
    static let mmprojv4_FileName = "mmproj-model-f16-iOS.gguf"
    
    /// MiniCPM 多模态-mmproj 模型 NAS 下载地址
    static let mmprojv4_URLString = "https://huggingface.co/openbmb/MiniCPM-V-4-gguf/resolve/main/mmproj-model-f16.gguf"

    static let mmprojv4_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4-gguf/repo?Revision=master&FilePath=mmproj-model-f16.gguf"
    
    /// 显示在 UI 上名字-mmproj
    static let modelMMProjv4_DisplayedName = "MiniCPM-V 4.0 4B VPM"
    
    /// mmproj gguf 文件 md5 值
    static let modelMMProjv4_MD5 = "fe15375bb4c579858df6054d2a8b639d"
    
    // MARK: - mbv4 ANE 利用模块
    
    /// ANE 利用压缩包 文件名
    static let mlmodelcv4_ZipFileName = "coreml_minicpmv40_vit_f16.mlmodelc.zip"
    
    /// ANE 模型压缩包下载地址
    static let mlmodelcv4_ZipFileURLString = "https://huggingface.co/openbmb/MiniCPM-V-4-gguf/resolve/main/coreml_minicpmv40_vit_f16.mlmodelc.zip"
    
    static let mlmodelcv4_ZipFileBackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4-gguf/repo?Revision=master&FilePath=coreml_minicpmv40_vit_f16.mlmodelc.zip"
    
    /// ANE 利用显示在设置页的名称
    static let mlmodelcv4_ZipFileDisplayedName = "MiniCPM-V 4.0 4B ANE"
    
    /// ANE 利用压缩包 md5
    static let mlmodelcv4_ZipFileMD5 = "150a316e49dee3da04d72039ee2ca390"
    
    
    // MARK: - MiniCPM-V 4.6 多模态语言模型

    /// V4.6 主模型文件名（落盘到 Documents/，命名带 v4.6 前缀以避免与 v2.6 / v4.0 同目录平铺时撞名）。
    /// 注意：这一份 LLM 在 OBS / HF / ModelScope 三方完全同源（同 MD5），切换下载源不会影响老用户已下载的本地文件，
    /// 也不需要 bump 文件名 / MD5。
    static let modelv46_FileName = "MiniCPM-V-4_6-Q4_K_M.gguf"

    /// V4.6 显示名
    static let modelv46_DisplayedName = "MiniCPM-V 4.6 LLM INT4"

    /// V4.6 主模型下载地址（HuggingFace 主源，对齐 v4 的源策略）
    static let modelv46_Q4_K_M_URLString = "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main/MiniCPM-V-4_6-Q4_K_M.gguf"

    /// V4.6 主模型备用下载地址（ModelScope 国内镜像，HF 不通时由 MBModelDownloadHelperV2 自动 fallback）
    static let modelv46_Q4_K_M_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4.6-gguf/repo?Revision=master&FilePath=MiniCPM-V-4_6-Q4_K_M.gguf"

    /// V4.6 主模型 md5（OBS / HF / ModelScope 三源同源，无需 bump）
    static let modelv46_Q4_K_M_MD5 = "fd778481dd56b6036dd8f9cf7c1519cf"


    // MARK: - MiniCPM-V 4.6 mmproj VIT 模型

    /// V4.6 mmproj 文件名（落盘到 Documents/）。
    ///
    /// 有意带 `-master-` 后缀：与 OBS demo fork 转出的旧 `merger` 版本区分。
    /// 两份互不兼容，换名让它们可以共存且 modelsExist() 不会误用旧文件。
    /// 旧名登记在 `staleMMProjv46_FileNames`，启动时主动 purge。
    static let mmprojv46_FileName = "MiniCPM-V-4_6-mmproj-master-f16.gguf"

    /// V4.6 mmproj 显示名
    static let modelMMProjv46_DisplayedName = "MiniCPM-V 4.6 VPM"

    /// V4.6 mmproj 下载地址（HuggingFace 主源）
    static let mmprojv46_URLString = "https://huggingface.co/openbmb/MiniCPM-V-4.6-gguf/resolve/main/mmproj-model-f16.gguf"

    /// V4.6 mmproj 备用下载地址（ModelScope 国内镜像，HF 不通时由 MBModelDownloadHelperV2 自动 fallback）
    static let mmprojv46_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM-V-4.6-gguf/repo?Revision=master&FilePath=mmproj-model-f16.gguf"

    /// V4.6 mmproj md5（HF / ModelScope 上的 OpenBMB 官方版本，跟 upstream master 兼容）
    static let modelMMProjv46_MD5 = "54aea6e04d752f47309a48f12795a1a3"

    /// 启动时主动 purge 的老 mmproj 文件名集合。
    ///
    /// 用途：处理"老用户从 OBS 下载过旧 demo-fork mmproj"的迁移场景。这份旧 mmproj 在 master
    /// 适配版本里已经不能用，但 modelsExist() fast-path 只看文件存在不校 MD5，会把残留文件直接
    /// 喂给 native 加载导致闪退（参照 AGENTS.md《客户端 ↔ OBS 模型一致性》一节）。
    static let staleMMProjv46_FileNames: [String] = [
        "MiniCPM-V-4_6-mmproj-f16.gguf",  // OBS demo-fork merger 版本，master 加载 fail
    ]
    
    
    // MARK: - MiniCPM 5 纯文本模型（1B）

    /// MiniCPM5 主模型文件名（对齐 HF / ModelScope 上的官方命名 `MiniCPM5-1B-Q4_K_M.gguf`）。
    /// 老文件名 `MiniCPM5-0.9B-Q4_K_M.gguf` 登记在 `staleModelv5_FileNames` 里，启动时主动 purge。
    static let modelv5_FileName = "MiniCPM5-1B-Q4_K_M.gguf"

    /// MiniCPM5 显示名
    static let modelv5_DisplayedName = "MiniCPM5-1B LLM INT4"

    /// MiniCPM5 主模型下载地址（HuggingFace 主源，对齐 v4.6 的源策略）
    static let modelv5_URLString = "https://huggingface.co/openbmb/MiniCPM5-1B-GGUF/resolve/main/MiniCPM5-1B-Q4_K_M.gguf"

    /// MiniCPM5 主模型备用下载地址（ModelScope 国内镜像，HF 不通时由 MBModelDownloadHelperV2 自动 fallback）
    static let modelv5_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM5-1B-GGUF/repo?Revision=master&FilePath=MiniCPM5-1B-Q4_K_M.gguf"

    /// MiniCPM5 主模型 MD5（HF / ModelScope 同源，sha256=81b64d05..）
    static let modelv5_MD5 = "a5f29552a5abcc0533f18066851fe8dc"

    /// 启动时主动 purge 的老 MiniCPM5 文件名集合。
    ///
    /// 用途：处理"老用户从 OBS 下载过旧 0.9B 命名版本"的迁移场景。旧文件在新的
    /// `modelv5_FileName = MiniCPM5-1B-Q4_K_M.gguf` 期望下不会被加载，但 1B 命名版本是
    /// 重转过的 gguf，字节级不同（HF 上 sha256 不同），强制让用户重新从 HF/MS 下载。
    static let staleModelv5_FileNames: [String] = [
        "MiniCPM5-0.9B-Q4_K_M.gguf",  // OBS 上的开源前 0.9B 命名版本
    ]


    // MARK: - MiniCPM5 纯文本模型（2B）

    /// MiniCPM5-2B 主模型文件名（对齐 HF / ModelScope 官方命名）。
    static let modelv526_FileName = "MiniCPM5-2B-Q4_K_M.gguf"

    /// MiniCPM5-2B 显示名
    static let modelv526_DisplayedName = "MiniCPM5-2B LLM INT4"

    /// MiniCPM5-2B 主模型下载地址（HuggingFace 主源，对齐 1B / v4.6）
    static let modelv526_URLString = "https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q4_K_M.gguf"

    /// MiniCPM5-2B 备用下载地址（ModelScope 国内镜像）
    static let modelv526_BackUpURLString = "https://modelscope.cn/api/v1/models/OpenBMB/MiniCPM5-2B-GGUF/repo?Revision=master&FilePath=MiniCPM5-2B-Q4_K_M.gguf"

    /// Official HF / ModelScope Q4_K_M size (LFS sha256=ec2d5801..).
    /// OBS pre-release copy was 1561318208 bytes; size mismatch triggers re-download.
    static let modelv526_ExpectedSize: Int64 = 1_561_318_368


    // MARK: - MiniCPM-V 4.6 ANE 模块
    
    /// V4.6 ANE CoreML 目录名（编译后的 .mlmodelc，或 Xcode 可直接加载的 .mlpackage 包）
    static let mlmodelcv46_DirName = "coreml_minicpmv46_vit_all_f32.mlmodelc"
    
    /// 在 Documents 中依次尝试的文件名（任一路径存在即作为 CoreML 路径）
    static let mlmodelcv46_CandidateFileNames: [String] = [
        "coreml_minicpmv46_vit_all_f32.mlmodelc",
        "coreml_minicpmv46_vit_all_f32.mlpackage",
        "coreml_minicpmv46_vit_all_f16.mlpackage",
    ]
    
    /// V4.6 ANE 显示名
    static let mlmodelcv46_DisplayedName = "MiniCPM-V 4.6 ANE"

    /// V4.6 ANE zip 文件名（下载到 Documents 后解压得到 .mlmodelc 目录）
    static let mlmodelcv46_ZipFileName = "coreml_minicpmv46_vit_all_f32.mlmodelc.zip"

    /// V4.6 ANE zip 下载地址。
    ///
    /// **当前为空**：原先托管在华为云 OBS 中转桶，该桶为内部中转用途，不适合对外发布
    /// （且对象已转 DEEP_ARCHIVE，匿名下载会返回 InvalidObjectState）。开源版不再内置该
    /// 资产 —— 需要 V4.6 ANE 的用户请自备 zip 放进 Documents，或改由公开托管提供后再填这里。
    static let mlmodelcv46_ZipFileURLString = ""

    /// V4.6 ANE zip md5（demo 分支重转：基于 ckpt/MiniCPM-V-4_6 封板权重 + HF 命名映射）
    static let mlmodelcv46_ZipFileMD5 = "4ea0fbdb9b975e411b0faf478beb1d84"


    // MARK: - VoxCPM2 语音合成模型

    /// VoxCPM2 BaseLM GGUF 文件名（~953 MB，Q4_K_M 量化）
    static let voxcpm2_BaseLMFileName = "VoxCPM2-BaseLM-Q4_K_M.gguf"

    /// VoxCPM2 BaseLM 显示名
    static let voxcpm2_BaseLMDisplayedName = "VoxCPM2 BaseLM Q4_K_M"

    /// VoxCPM2 BaseLM 下载地址（HuggingFace 主源）
    static let voxcpm2_BaseLMURLString = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/VoxCPM2-BaseLM-Q4_K_M.gguf"

    /// VoxCPM2 BaseLM 备用下载地址（ModelScope，国内直连）
    static let voxcpm2_BaseLMMSURLString = "https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master/VoxCPM2-BaseLM-Q4_K_M.gguf"
    

    /// VoxCPM2 BaseLM Q4_K_M gguf 文件 md5 值
    static let voxcpm2_BaseLMMD5 = "d8cd571526464d225187d326caa289be"

    /// VoxCPM2 Acoustic GGUF 文件名（~1.7 GB）
    static let voxcpm2_AcousticFileName = "VoxCPM2-Acoustic-F16.gguf"

    /// VoxCPM2 Acoustic 显示名
    static let voxcpm2_AcousticDisplayedName = "VoxCPM2 Acoustic"

    /// VoxCPM2 Acoustic 下载地址（HuggingFace 主源）
    static let voxcpm2_AcousticURLString = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/VoxCPM2-Acoustic-F16.gguf"

    /// VoxCPM2 Acoustic 备用下载地址（ModelScope，国内直连）
    static let voxcpm2_AcousticMSURLString = "https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master/VoxCPM2-Acoustic-F16.gguf"

    /// VoxCPM2 Acoustic F16 gguf 文件 md5 值
    static let voxcpm2_AcousticMD5 = "0f16229cfffe935102d21433f6969f8b"

    /// VoxCPM2 整体显示名
    static let voxcpm2_DisplayedName = "VoxCPM2 (TTS)"

}

/// 一个可下载文件：仓库内路径 + 落盘到 `Documents/<documentsDirName>/` 下的相对名 +
/// 期望字节数（用于进度条总长与下载后校验）。
struct ModelDownloadFile {
    let remotePath: String
    let localName: String
    let bytes: Int64
}

/// MiniCPM-V 4.7 (35a3_hf_v47) MoE SSD — 文本塔 qwen35moe + 视觉塔 minicpmv4_6。
/// 文件放在 App Documents 下（`MiniCPMV47/`），由外部写入（USB 推送 / 后续的公网下载）。
/// MiniCPM-V 4.7 **1B**（dense）：文本塔 qwen35（24 层、无专家、无 experts），
/// 视觉塔 `clip.projector_type = minicpmv4_7`（结构与 4.6 同构，走 llava-uhd 切片）。
///
/// 与 35B-A3B 分成两个目录，方便同一台设备上共存做 A/B（1B 全量约 1.8 GB）。
/// 权重放在 App Documents 下，由外部写入（USB 推送 / 公网下载）。
struct MiniCPMV47_1BConst {
    static let userDefaultsKey = "MiniCPMV47_1B"
    static let displayedName = "MiniCPM-V 4.7 1B"
    static let documentsDirName = "MiniCPMV47_1B"
    /// 默认量化：q4_k_m（HF `openbmb/MiniCPM-V-4.7-1B-gguf` 上的原名）。
    static let modelFileName = "MiniCPM-V-4_7-1B-Q4_K_M.gguf"
    static let mmprojFileName = "mmproj-model-f16.gguf"
    /// 16x 下单图最多 640 token（`1+9` 贴图），4096 留足文本与输出余量。
    /// 若换 4x 塔（每贴图 256 token、单图上限 2560），这里必须一起抬。
    static let defaultNCtx = 4096

    /// 公网托管（下载源，两个源竞速；任一可用即可）。
    ///
    /// 托管在作者的个人 HF/MS 仓库下，按模型分子目录。换仓库或换量化时
    /// `downloadFiles` 里的路径要一起改。
    static let hfBase = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main"
    static let msBase = "https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master"

    /// 需要下载的文件（1B 只需主模型 + mmproj）。
    static var downloadFiles: [ModelDownloadFile] {
        [
            ModelDownloadFile(remotePath: "MiniCPM-V-4.7-1B/\(modelFileName)",
                              localName: modelFileName,
                              bytes: 672_003_584),
            ModelDownloadFile(remotePath: "MiniCPM-V-4.7-1B/\(mmprojFileName)",
                              localName: mmprojFileName,
                              bytes: 1_108_746_816),
        ]
    }

    struct Artifacts {
        let modelURL: URL
        let mmprojURL: URL
    }

    /// 在 `Documents/MiniCPMV47_1B/` 下找两个文件，缺任何一个返回 nil。
    static func resolveArtifacts(in documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) -> Artifacts? {
        let root = documentsDirectory.appendingPathComponent(documentsDirName)
        let fm = FileManager.default
        let model = root.appendingPathComponent(modelFileName)
        let mmproj = root.appendingPathComponent(mmprojFileName)
        guard fm.fileExists(atPath: model.path), fm.fileExists(atPath: mmproj.path) else {
            return nil
        }
        return Artifacts(modelURL: model, mmprojURL: mmproj)
    }

    static var filesExist: Bool { resolveArtifacts() != nil }
}

struct MiniCPMV47Const {
    static let userDefaultsKey = "MiniCPMV47"
    static let displayedName = "MiniCPM-V 4.7 35B-A3B"
    /// 默认量化 q3gud-im（Q3_K 专家）。
    ///
    /// `-les` = 路由专家已剥离、改由 `experts/` 目录按需流式读取（见
    /// `docs/les/lookahead-expert-scheduling.md`）。引擎默认开 mmap，必须喂这个变体：
    /// 带专家的完整版在 mmap 下会把整文件包成一个 Metal buffer 而 OOM。
    /// 换量化用 `-moeModel` 覆盖。
    static let modelFileName = "MiniCPM-V-4_7-35B-A3B-mix_q3gud_im-les.gguf"
    static let mmprojFileName = "mmproj-model-f16.gguf"
    static let expertsDirName = "experts"

    /// 公网托管（下载源，两个源竞速）。
    static let hfBase = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main"
    static let msBase = "https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master"

    /// experts 目录里 layer 分片的个数与单片字节数。
    ///
    /// 分片名固定为 `layer_%03d.bin`，每片等大（一个 layer 的全部路由专家）。
    /// 换量化要一起改这两项；下载完由 `expertsProblems()` 用 manifest 再验一遍。
    static let expertLayerCount = 40
    static let expertLayerBytes: Int64 = 346_030_080

    /// 需要下载的文件：主模型 + mmproj + experts 的 manifest 与全部分片。
    ///
    /// 顺序有意为之：manifest 最先（小、能最快确认布局），接着主模型与 mmproj，
    /// 最后 40 个分片（最占时间）。
    static var downloadFiles: [ModelDownloadFile] {
        let dir = "MiniCPM-V-4.7-35B-A3B"
        var files: [ModelDownloadFile] = [
            ModelDownloadFile(remotePath: "\(dir)/\(expertsDirName)/manifest.json",
                              localName: "\(expertsDirName)/manifest.json", bytes: 73_668),
            ModelDownloadFile(remotePath: "\(dir)/\(modelFileName)",
                              localName: modelFileName, bytes: 1_662_732_800),
            ModelDownloadFile(remotePath: "\(dir)/\(mmprojFileName)",
                              localName: mmprojFileName, bytes: 1_119_575_840),
        ]
        for i in 0..<expertLayerCount {
            let name = String(format: "layer_%03d.bin", i)
            files.append(ModelDownloadFile(remotePath: "\(dir)/\(expertsDirName)/\(name)",
                                           localName: "\(expertsDirName)/\(name)",
                                           bytes: expertLayerBytes))
        }
        return files
    }
    /// 手机上落盘目录。必须放子目录：mmproj 文件名与 V2.6 的
    /// `mmproj-model-f16.gguf` 同名，平铺在 Documents 根会互相覆盖。
    static let documentsDirName = "MiniCPMV47"
    static let slotBankDefaultsKey = "moe_slot_bank"
    static let defaultSlotBank = 256
    static let minSlotBank = 8
    static let slotBankStep = 8
    /// 35a3_hf_v47 routed expert_count
    static let maxSlotBank = 256
    /// 上下文长度。2048 会被「带图 + 多轮」顶穿：一张 9 切片图约 447 token，
    /// 视频帧每帧 80+，累积几轮就没地方给输出了（表现为输出被截断）。
    ///
    /// 提到 4096 的代价很小：V47 只有 10 层带 KV，实测 20 KiB/token，
    /// 2048 → 4096 只多 40 MiB；`decodeWindowKv32kExtraMiB()` 会自动把这笔
    /// 算进内存预留（2400 → 2440 MiB），不用手工改预算。
    static let defaultNCtx = 4096
    /// 对 minicpmv4_6 视觉塔**无效**：`clip.cpp` 的 MINICPMV4_6 分支不调
    /// `set_limit_image_tokens`，mmproj dump 出来 `image_max_pixels = -1`（已实测）。
    /// 留着只作兜底：万一又换成 Qwen-VL 那种 dyn_size 塔，这根旋钮能防像素预算失控。
    static let defaultImageMaxTokens = 512
    /// V4.7 真正生效的图像预算旋钮 = 切片数（1 overview + ≤N 片，每片 ≤448²，56 对齐）。
    /// 走 `ImageSliceSetting`（用户可在对话页调 1…9），这里只是冷启动缺省值。
    static var defaultSliceNums: Int { ImageSliceSetting.defaultSlice }
    /// V4.7 mmproj（`clip.projector_type = minicpmv4_7`）的 md5 与字节数。
    /// 必须带 `v.tok_embd_sep` 张量的版本，否则与新引擎不匹配。
    /// 注意：加载路径不做 md5 校验（只查存在性），此值只用于公网下载的末端校验。
    static let mmprojMD5 = "2a705dfc7184f504086f48bd109e27a2"
    static let mmprojExpectedBytes: Int64 = 1_119_575_840

    /// DSpark 草稿模型（Q8_0，35B-A3B 的 DFlash + Markov 头）的 md5 与字节数。
    /// 改文件名或重新量化时，这两项要和 `draftFileName` / `draftRemotePath` 一起改，
    /// 否则下载器会拿新文件对旧 md5，直接报「md5 不对」。
    static let draftMD5 = "5baaabfb8f7e8a2f87786b4c179ac513"
    static let draftExpectedBytes: Int64 = 424_570_592

    /// Shared bank=256 能装下一层全部专家，ubatch 不再按 bank/8 夹。1024 覆盖长文梳理。
    static let defaultNUbatch = 1024

    /// 启动参数覆盖，供内存/预填实验用：`-moeUbatch N`。
    ///
    /// 小 ub 对短 prompt 的 decode 有 ~22% 收益，但 prompt 超过 ub 会切段、
    /// 每段重读专家，长/带图场景必须显式传 1024。实测表见
    /// Comni/v47/ios-app-调优参数与实测.md §1。与 -moeSlotBank 同理由：必须命令行注入。
    static func nUbatch() -> Int {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeUbatch"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]), v > 0 {
            return v
        }
        return defaultNUbatch
    }

    /// `-moeModel <文件名>`：覆盖主模型文件名（默认 `modelFileName`）。
    ///
    /// 用途：**同一台设备上并存多份量化做 A/B**。否则换一份量化要把 20 GB 的 experts
    /// 重推一遍（实测 USB 约 36 MB/s，来回 15 分钟），完全没法迭代。
    /// 配合 `-moeExpertsDir` 使用，两份可以各自独立。
    static func modelFileNameResolved() -> String {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeModel"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            return ProcessInfo.processInfo.arguments[i + 1]
        }
        return modelFileName
    }

    /// `-moeExpertsDir <目录名>`：覆盖 experts 目录名（默认 `experts`）。
    static func expertsDirNameResolved() -> String {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeExpertsDir"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            return ProcessInfo.processInfo.arguments[i + 1]
        }
        return expertsDirName
    }

    // ── DSpark 投机解码 ───────────────────────────────────────────────────────
    //
    // 草稿模型权重不随仓库分发；设备上找不到文件时静默关闭投机，行为与不启用时完全一致。

    /// DSpark 草稿模型文件名。默认与主模型放在同一个目录（`documentsDirName` 下）。
    /// 换成别的量化 / 别的落盘位置用启动参数 `-draftModel` 覆盖。
    static let draftFileName = "MiniCPMV47-DSpark-Q8_0.gguf"

    /// 草稿模型的目标落盘名（不带 `35B-A3B`）。
    /// 与公网仓库里的原始文件名刻意不同；下载器靠 remote/dest 名分离把两者接起来。
    static let draftRemotePath = "drafts/MiniCPMV47-35B-A3B-DSpark-Q8_0.gguf"

    /// `-draftModel <文件名或绝对路径>`：覆盖草稿模型文件名/路径。
    static func draftModelFileNameResolved() -> String {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-draftModel"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            return ProcessInfo.processInfo.arguments[i + 1]
        }
        return draftFileName
    }

    /// 草稿模型在本地是否可用。`nil` = 可用；否则返回可直接展示给用户的原因。
    /// 草稿不参与主模型的完整性判断（`resolveArtifacts()` 不看它），所以设置页在用户
    /// 打开开关的那一刻单独查一次。查找顺序与 `resolveDraftModelPath` 保持一致。
    static func dsparkDraftProblem(in documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) -> String? {
        let name = draftModelFileNameResolved()
        let fm = FileManager.default

        var candidates: [URL] = []
        if name.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: name))
        } else {
            candidates.append(documentsDirectory.appendingPathComponent(documentsDirName).appendingPathComponent(name))
            candidates.append(documentsDirectory.appendingPathComponent(name))
        }

        guard let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return "缺少草稿模型 \(name)（约 \(draftExpectedBytes / 1_048_576) MiB）。"
        }
        let size = ((try? fm.attributesOfItem(atPath: found.path))?[.size] as? Int64) ?? 0
        if size != draftExpectedBytes {
            return "草稿模型 \(name) 大小不对（\(size) / \(draftExpectedBytes) 字节），可能没下完。"
        }
        return nil
    }

    /// `-specNMax <n>`：每轮草稿数 n_max 的请求值，默认 4，上限 16（DSpark 的块宽）。
    /// 这是「想要多少」，真正可用的值还要过 `effectiveSpecDraftNMax(windowSlots:)`。
    static func specDraftNMaxResolved() -> Int {
        guard dsparkEnabled() else { return 0 }
        var v = 4
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-specNMax"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let n = Int(ProcessInfo.processInfo.arguments[i + 1]) {
            v = n
        }
        return min(max(v, 0), 16)
    }

    /// DSpark 总开关的持久化 key。必须跨启动保留 —— 模型在 App 启动时加载，
    /// 用户在设置页改完开关要靠下次启动才生效。
    private static let dsparkEnabledDefaultsKey = "dspark_enabled"
    /// 一次性迁移：把曾持久化为「开」的 DSpark 开关重置为关。
    private static let dsparkDefaultOffMigratedKey = "dspark_default_off_migrated_v1"

    static func migrateDsparkDefaultOffIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: dsparkDefaultOffMigratedKey) else { return }
        ud.set(false, forKey: dsparkDefaultOffMigratedKey)
        if ud.bool(forKey: dsparkEnabledDefaultsKey) {
            ud.set(false, forKey: dsparkEnabledDefaultsKey)
            ud.synchronize()
            print("[MODEL] DSpark 默认关闭：已把持久化的开关重置为关")
        }
    }

    /// DSpark 投机解码总开关，默认关。真机上「窗口 + 草稿模型 + mmproj」会越过 8 GB iPhone
    /// 的 4 GiB per-app 限额而被 jetsam 杀；打开后需配合 `-moeTextOnly` 启动（不加载 mmproj）。
    /// 启动参数 `-specNMax N` 优先于本开关（N > 0 强制开、N = 0 强制关）。
    static func dsparkEnabled() -> Bool {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-specNMax"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]) {
            return v > 0
        }
        return UserDefaults.standard.bool(forKey: dsparkEnabledDefaultsKey)
    }

    static func setDsparkEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: dsparkEnabledDefaultsKey)
    }

    /// 把请求的 `n_max` 夹到窗口真正装得下的范围：引擎侧
    /// `window_max_rows = 可用 slot / n_expert_used`，而验证批是 `n_max + 1` 行。
    /// 一旦装不下就会整批掉出窗口，实测速度从约 20 t/s 掉到 2.34 t/s。
    /// - Parameter windowSlots: 每层可用 slot 数（= 缓存区 c + 预读区 K）。
    static func effectiveSpecDraftNMax(windowSlots: Int) -> Int {
        let requested = specDraftNMaxResolved()
        guard requested > 0 else { return 0 }

        // 与引擎的 window_max_rows 用同一个式子：可用 slot / 每 token 用几个专家。
        let maxRows = max(1, windowSlots / expertUsed)
        let maxNMax = max(0, maxRows - 1)          // 验证批 = n_max + 1 行

        if requested > maxNMax {
            print("[MODEL] DSpark: n_max \(requested) -> \(maxNMax)"
                  + "（窗口 \(windowSlots) slot/层 只覆盖 \(maxRows) 行，验证批需 \(requested + 1) 行）")
            if maxNMax == 0 {
                print("[MODEL] DSpark off: 窗口装不下任何验证批（需 >= \(2 * expertUsed) slot/层）")
                return 0
            }
        }
        return min(requested, maxNMax)
    }

    /// 解析草稿模型的绝对路径；找不到文件（或 `-specNMax 0`）返回空字符串 = 关闭投机。
    /// 查找顺序与 `resolveArtifacts` 一致：Documents/<documentsDirName>/ 优先，然后 Documents 根。
    static func resolveDraftModelPath(in documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) -> String {
        guard specDraftNMaxResolved() > 0 else {
            print("[MODEL] DSpark off (-specNMax 0)")
            return ""
        }
        let name = draftModelFileNameResolved()
        let fm = FileManager.default
        if name.hasPrefix("/") {
            if fm.fileExists(atPath: name) {
                print("[MODEL] resolved draft=\(name) (绝对路径)")
                return name
            }
            print("[MODEL] draft model not found (\(name)) → DSpark off")
            return ""
        }
        let roots = [
            documentsDirectory.appendingPathComponent(documentsDirName),
            documentsDirectory
        ]
        for root in roots {
            let p = root.appendingPathComponent(name)
            if fm.fileExists(atPath: p.path) {
                print("[MODEL] resolved draft=\(name) root=\(root.lastPathComponent)")
                return p.path
            }
        }
        print("[MODEL] draft model not found (\(name)) → DSpark off")
        return ""
    }

    /// V47 的 n_expert_used（每 token 每层用几个专家）。
    static let expertUsed = 8

    /// 每层 decode 窗口的宽度（slot 数），0 = 不启用。
    ///
    /// 窗口分「缓存区 c（跨 token LRU）」与「预读区 K（下层预测重填）」。
    /// 同样内存下缓存 slot 更值钱，但 K 不能归零（少量预读补冷启动），K=4 是甜点。
    /// 预算 = 余量 - reserve，(c+K) = 预算 / (每 slot 字节 × 层数)。
    /// 实测表与 reserve 分解见 Comni/v47/ios-app-调优参数与实测.md §6。
    static func maxCFromBudget(bytesPerSlot: Int64, kSlots: Int) -> Int {
        let available = Int64(MBDeviceMemoryProbe.availableProcessBytes)
        let footprint = Int64(MBDeviceMemoryProbe.footprintBytes)
        let ceilingGiB = decodeWindowMemCeilingGiB()
        let ceiling = Int64(ceilingGiB) * 1024 * 1024 * 1024
        let byCeiling = ceiling - footprint
        let headroom = available > 0 ? min(available, max(0, byCeiling)) : max(0, byCeiling)
        guard headroom > 0 else { return 0 }

        let usesMmap = !ProcessInfo.processInfo.arguments.contains("-moeNoMmap")
        let reserve: Int64 = (Int64(decodeWindowMemReserveMiB() + decodeWindowDsparkReserveMiB())
                              + (usesMmap ? 0 : 1_600)) * 1024 * 1024
        let budget = headroom - reserve
        guard budget > 0 else { return 0 }

        let nLayers: Int64 = 40
        // 预算覆盖 (c + K)：引擎的 -moeDecodeWindow 只表示**缓存区 c**，
        // 预读区 K 由引擎按预读深度另加（见 llama-moe-slot.cpp 的 resolve_decode_window）。
        let totalSlots = budget / (bytesPerSlot * nLayers)
        let cacheSlots = totalSlots - Int64(kSlots)
        guard cacheSlots > 0 else { return 0 }
        return Int(cacheSlots)
    }

    static func decodeWindow(expertsURL: URL) -> Int {
        // 启动参数优先，供实验用（与 slotBank / nUbatch 同一约定）。
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeDecodeWindow"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]) {
            return max(0, v)
        }

        // 配合预读时，模型侧每层张量宽度 = c + K；这里算的是**总宽度**，
        // 运行时再按 K 切分成 [缓存区 | 预读区]。
        let kSlots = decodeWindowPrefetchSlots()   // 默认 4；预读关时为 0

        guard let bytesPerSlot = bytesPerSlot(at: expertsURL), bytesPerSlot > 0 else {
            return 0
        }

        // 用户设的 c 仍要过预算闸：不扣 reserve 会挤掉 mmproj 等常驻，甚至卡死整机。
        let requested = clampCacheWindowC(cacheWindowC())
        // c=0：关掉整扇专家窗口（引擎语义），不走预算夹紧、也不加预读宽度。
        if requested == 0 {
            let line = "[MODEL] decode window: c=0 (window off)"
            print(line)
            NSLog("%@", line)
            return 0
        }
        let budgetMax = maxCFromBudget(bytesPerSlot: bytesPerSlot, kSlots: kSlots)
        var c: Int
        if budgetMax > 0 {
            c = clampCacheWindowC(min(requested, budgetMax))
            if c != requested {
                print("[MODEL] 缓存 c=\(requested) 超出预算允许的 \(budgetMax)"
                      + "（预算已扣掉 reserve）→ 夹到 c=\(c)")
            }
        } else {
            // 闸门不可用，不能原样放行，退到设备默认档。
            c = min(requested, deviceDefaultCacheWindowC())
            print("[MODEL] 预算闸不可用 → 缓存取设备默认 c=\(c)（请求值 \(requested) 未采用）")
        }
        let windowMiB = Int64(c + kSlots) * 40 * bytesPerSlot / 1048576
        let line = "[MODEL] decode window: c=\(c) K=\(kSlots) (window \(windowMiB) MiB)"
            + " <- 设置里指定 c=\(requested)"
            + "，覆盖率 \(String(format: "%.0f%%", 100.0 * cacheWindowCoverage(c)))"
        print(line)
        NSLog("%@", line)
        return c
    }

    // ── 缓存大小设置（设置页那一行）────────────────────────────────────────

    /// 每层缓存槽数 c，即引擎的 `-moeDecodeWindow`。暴露 c 而不是总内存：
    /// c 直接决定覆盖率与 miss 率，内存占用是它的结果。
    static let cacheWindowDefaultsKey = "moe_cache_window_c"
    static let cacheWindowStepC = 8
    /// 滑条下限。0 = 关闭整扇专家窗口（引擎 `-moeDecodeWindow 0`）。
    static let minCacheWindowC = 0
    /// 窗口开着时的下限：本模型一步要用 8 个专家，小于 8 的正数会抬到 8。
    static let minEnabledCacheWindowC = 8

    /// 按设备物理内存给的默认 c：16 GB → 128，12 GB → 48，8 GB → 24。
    /// 阈值取 13.5 / 9.5 是因为上报值小于标称（实测 15.14 / 7.45 GiB）。
    ///
    /// ⚠️ 必须明显小于设备上限：崩溃回退会把 c 清掉、重落到本默认档，若默认档本身
    /// 就是崩的那个值，回退机制就永远逃不出来。
    static func deviceDefaultCacheWindowC() -> Int {
        let gib = devicePhysicalGiB()
        if gib >= 13.5 { return 128 }
        if gib >= 9.5  { return 48 }
        if gib >= 6.5  { return 24 }
        return minEnabledCacheWindowC
    }

    /// 首次按设备写入默认 c；用户设过不动。
    static func seedCacheWindowDefaultIfNeeded() {
        let ud = UserDefaults.standard
        let gib = devicePhysicalGiB()
        if gib >= 6.5 && gib < 9.5,
           ud.object(forKey: cacheWindowDefaultsKey) != nil {
                // 48 和 32 都是「系统给过的默认」而非用户手选，直接收到 24。
            let stored = ud.integer(forKey: cacheWindowDefaultsKey)
            if stored == 48 || stored == 32 {
                ud.set(24, forKey: cacheWindowDefaultsKey)
                ud.synchronize()
                print(String(format: "[MODEL] 8GB 默认专家缓存 %d→24（物理内存 %.2f GiB）", stored, gib))
                return
            }
        }
        if gib >= 9.5 && gib < 13.5,
           ud.object(forKey: cacheWindowDefaultsKey) != nil {
                // 64 和 0 都是历史上系统给过的旧默认，不该留在这个档位上，收到 48。
                // （0 = 曾误设成关窗口，真实多模态实测窗口开快 40~50%）
            let stored = ud.integer(forKey: cacheWindowDefaultsKey)
            if stored == 64 || stored == 0 {
                ud.set(48, forKey: cacheWindowDefaultsKey)
                ud.synchronize()
                print(String(format: "[MODEL] 12GB 专家缓存 %d→48（物理内存 %.2f GiB，真实会话实测窗口开更快）", stored, gib))
                return
            }
        }
        guard ud.object(forKey: cacheWindowDefaultsKey) == nil else { return }
        let d = deviceDefaultCacheWindowC()
        ud.set(d, forKey: cacheWindowDefaultsKey)
        ud.synchronize()
        print(String(format: "[MODEL] 按设备内存 %.2f GiB 设定默认专家缓存 c=%d", gib, d))
    }
    /// 旋钮上限，按设备分档：16 GB → 144，12 GB → 80，8 GB → 32。
    /// 分档是因为 `maxCFromBudget()` 有「算不出就放行」的退路。
    static func maxCacheWindowCForDevice() -> Int {
        let gib = devicePhysicalGiB()
        if gib >= 13.5 { return 144 }
        if gib >= 9.5  { return 80 }
        if gib >= 6.5  { return 32 }
        return minEnabledCacheWindowC * 2
    }

    static func clampCacheWindowC(_ raw: Int) -> Int {
        // 0 是合法值（关窗口）。1–3 靠向 0；4–7 抬到 8（一步至少装下本层专家数）。
        if raw < cacheWindowStepC / 2 { return 0 }
        let stepped = (raw / cacheWindowStepC) * cacheWindowStepC
        return min(max(stepped, minEnabledCacheWindowC), maxCacheWindowCForDevice())
    }

    /// 设置页显示的当前值。没写过 key 才用设备默认档；显式写成 0 就是关窗口。
    static func cacheWindowC() -> Int {
        let ud = UserDefaults.standard
        guard ud.object(forKey: cacheWindowDefaultsKey) != nil else {
            return deviceDefaultCacheWindowC()
        }
        return clampCacheWindowC(ud.integer(forKey: cacheWindowDefaultsKey))
    }

    static func setCacheWindowC(_ raw: Int) {
        UserDefaults.standard.set(clampCacheWindowC(raw), forKey: cacheWindowDefaultsKey)
    }

    static func clearCacheWindowC() {
        UserDefaults.standard.removeObject(forKey: cacheWindowDefaultsKey)
    }

    // ── 缓存预热（设置页那一行）──
    // 档位 = 每层条数。加权表 w8..w64 偏向首响，均匀表 u8..u64 留给 A/B。
    // 代价：读盘在首 token 之前、不与计算重叠，且每轮 park 后都要重来。
    static let prewarmLevels = [8, 16, 32, 48, 64, 96]
    static let defaultPrewarmLevel = 32
    static let prewarmLevelDefaultsKey = "moe_prewarm_level"

    /// 预热档位的设备上限：预热写进**缓存区**（引擎侧 cache_only），容量 = c，
    /// 所以表不能超过当前 c。c=0（窗口关）时预热无效，返回 0。
    /// 小内存设备（如 8 GB iPhone，c 默认 24）会自动把 32/48/64/96 挡在设置页外。
    static func maxPrewarmLevelForDevice() -> Int {
        let c = cacheWindowC()
        if c <= 0 { return 0 }
        return prewarmLevels.filter { $0 <= c }.max() ?? 0
    }

    /// 本机可选的预热档位（已按 c 过滤）。可能为空（c=0 时）。
    static func prewarmLevelsForDevice() -> [Int] {
        let cap = maxPrewarmLevelForDevice()
        return prewarmLevels.filter { $0 <= cap }
    }

    static func clampPrewarmLevel(_ raw: Int) -> Int {
        if raw <= 0 { return 0 }
        let allowed = prewarmLevelsForDevice()
        guard let fallback = allowed.last else { return 0 }
        // 取最接近的合法档位，避免存进非法值后被 bridge 静默关掉。
        return allowed.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? fallback
    }

    /// 当前档位；0 = 关。首次启动按 `defaultPrewarmLevel`（但不超过设备上限）。
    static func prewarmLevel() -> Int {
        let ud = UserDefaults.standard
        guard ud.object(forKey: prewarmLevelDefaultsKey) != nil else {
            return min(defaultPrewarmLevel, maxPrewarmLevelForDevice())
        }
        return clampPrewarmLevel(ud.integer(forKey: prewarmLevelDefaultsKey))
    }

    static func setPrewarmLevel(_ raw: Int) {
        UserDefaults.standard.set(clampPrewarmLevel(raw), forKey: prewarmLevelDefaultsKey)
    }

    // ── 预热表（固定 K4-total-1）──────────────────────────────────────────
    //
    // 预热固定用「全部 12 个 showcase case 聚类」出的 K=4 表里 total 目标第 1 组
    // （每层 96 条，bridge 会按窗口 c 截断）。此前设置页可在 8 张集群表之间切换，
    // 现已固定为 K4-total-1，不再暴露该设置。
    static func prewarmTableId() -> Int { 1 }

    // MARK: - 流式 markdown 实时渲染

    /// 输出框内是否在**生成过程中**就实时渲染 markdown。
    ///
    /// 默认 **关闭**（保持旧行为：流式期间纯文本，生成结束才整体上 markdown）。
    /// 打开后走 `StreamingMarkdownRenderer` 增量解析，边生成边上样式；代价是
    /// markdown 在标记闭合的瞬间会让渲染高度回缩，尽管已用「高度只增不减」压制，
    /// 观感仍可能不如纯文本阶段稳。
    static let streamingMarkdownDefaultsKey = "streaming_markdown_enabled"

    static func streamingMarkdownEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: streamingMarkdownDefaultsKey)
    }

    static func setStreamingMarkdownEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: streamingMarkdownDefaultsKey)
    }

    /// 「显示 P/D 速度」开关的持久化 key。0 = 不显示（默认），1 = 在回复底部工具条显示。
    ///
    /// 为什么做成设置项而不是编译期常量：调试与录制 case 时要频繁切换
    /// （录屏不希望带上 t/s，调参时又必须看到）。改常量要重编，改这个只要拨一下开关。
    ///
    /// 单位与来源见 `MTMDWrapper.lastPerfDisplayString()` —— 它就是 `[MBMtmd] perf app:`
    /// 那一行算的同一份数据（prefill/decode 各自的 tokens 与 ms），与 native 行不会不一致。
    static let showPerfSpeedDefaultsKey = "show_perf_speed"

    static func showPerfSpeedEnabled() -> Bool {
        // 默认**开** —— 保持「一直能看到速度」这个原有行为；要录干净的画面再拨关闭。
        let ud = UserDefaults.standard
        guard ud.object(forKey: showPerfSpeedDefaultsKey) != nil else { return true }
        return ud.bool(forKey: showPerfSpeedDefaultsKey)
    }

    static func setShowPerfSpeedEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: showPerfSpeedDefaultsKey)
    }

    /// 「实时速度」：生成过程中在输出框底部实时显示 decode t/s（与上面那个
    /// 「显示 P/D 速度」分工不同 —— 那个只在**生成结束后**给最终值）。
    static let liveTpsDefaultsKey = "show_live_tps"

    static func liveTpsEnabled() -> Bool {
        let ud = UserDefaults.standard
        guard ud.object(forKey: liveTpsDefaultsKey) != nil else { return true }
        return ud.bool(forKey: liveTpsDefaultsKey)
    }

    static func setLiveTpsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: liveTpsDefaultsKey)
    }

    /// 「OCR 实时速度」：OCR 推理过程中在预览上方显示 decode t/s。
    /// 和聊天的「实时速度」分开，互不影响。
    static let ocrLiveTpsDefaultsKey = "show_ocr_live_tps"

    static func ocrLiveTpsEnabled() -> Bool {
        let ud = UserDefaults.standard
        guard ud.object(forKey: ocrLiveTpsDefaultsKey) != nil else { return true }
        return ud.bool(forKey: ocrLiveTpsDefaultsKey)
    }

    static func setOcrLiveTpsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ocrLiveTpsDefaultsKey)
    }

    /// 覆盖率（c / 一层专家总数），用于设置页显示。
    static func cacheWindowCoverage(_ c: Int) -> Double {
        Double(min(c, maxSlotBank)) / Double(maxSlotBank)
    }

    /// 侧车目录（用来读每 slot 字节、把 c 换算成内存占用给用户看）。
    static func expertsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(documentsDirName)
            .appendingPathComponent(expertsDirName)
    }

    /// 给定 c，窗口实际占多少 GiB（只在 experts 可读时算得出）。
    static func windowGiB(forC c: Int, kSlots: Int) -> Double? {
        guard let bytesPerSlot = bytesPerSlot(at: expertsDirectoryURL()), bytesPerSlot > 0 else {
            return nil
        }
        // 关窗口时不分配 c、也不分配预读区。
        if c <= 0 { return 0 }
        let nLayers: Int64 = 40
        let bytes = Double(Int64(c + kSlots) * nLayers * bytesPerSlot)
        return bytes / (1024.0 * 1024.0 * 1024.0)
    }

    // ── 安全网：防止某个 c 让 App 起不来 ──────────────────────────────────
    //
    // 加载前落 `pending`，加载成功才清；启动时若 pending 还在，说明上个进程没走完，
    // 回退到默认档并提示。副作用：正常划掉 App 也会留下 pending，下次会重置设定。
    private static let cacheWindowPendingKey = "moe_cache_window_pending"
    private static let cacheWindowRevertedKey = "moe_cache_window_reverted"
    private static let cacheWindowRevertedValueKey = "moe_cache_window_reverted_value"

    /// 加载前调用，标记本次设定尚未验证。必须 synchronize()（异步写盘赶不上）。
    static func markCacheWindowLoadStarted() {
        let ud = UserDefaults.standard
        ud.set(true, forKey: cacheWindowPendingKey)
        ud.synchronize()
    }

    /// 加载成功后调用：清掉标记，表示这一档是能起来的。
    static func markCacheWindowLoadOk() {
        let ud = UserDefaults.standard
        ud.set(false, forKey: cacheWindowPendingKey)
        ud.set(false, forKey: cacheWindowRevertedKey)
        ud.synchronize()
    }

    /// 救援用：清掉存下来的 c，回到默认档。配合 `-moeCacheWindowReset` 启动参数，
    /// 用于某个 c 把 App 弄成「一开就卡死」、连设置页都进不去的场景。
    static func resetCacheWindowC() {
        UserDefaults.standard.removeObject(forKey: cacheWindowDefaultsKey)
        UserDefaults.standard.removeObject(forKey: cacheWindowPendingKey)
        UserDefaults.standard.synchronize()
    }

    /// 上次启动是否因为「缓存设太大、加载失败」而被回退到自动。
    /// 返回被回退掉的那个 c（没有则 nil）；**读完即清**，避免反复提示。
    static func consumeCacheWindowRevertNotice() -> Int? {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: cacheWindowRevertedKey) else { return nil }
        let attempted = ud.integer(forKey: cacheWindowRevertedValueKey)
        ud.set(false, forKey: cacheWindowRevertedKey)
        ud.removeObject(forKey: cacheWindowRevertedValueKey)
        return attempted > 0 ? attempted : nil
    }

    /// 若上次加载没走到成功点 → 回退到自动，并记录被回退掉的值。
    /// **必须在 `application(_:didFinishLaunchingWithOptions:)` 里、且只调一次** ——
    /// 恢复检查看的是「上一个进程有没有走完」，放进加载路径会读到本次刚置上的 pending。
    static func applyCacheWindowCrashRecoveryIfNeeded() {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: cacheWindowPendingKey) else { return }
        let attempted = cacheWindowC()
        ud.set(false, forKey: cacheWindowPendingKey)
        if attempted > 0 {
            clearCacheWindowC()
            ud.set(true, forKey: cacheWindowRevertedKey)
            ud.set(attempted, forKey: cacheWindowRevertedValueKey)
            print("[MODEL] 上次加载未成功（c=\(attempted) 可能过大）→ 已回退为设备默认档")
        }
    }

    /// 整机给本 App 的内存额度（GiB），窗口预算的硬上限，按设备分档：
    /// 16 GB → 11，12 GB → 6，8 GB → 5。
    /// 必须分档才能兜住探针高报（headroom 取 `min(探针, ceiling - footprint)`）。
    /// `-moeMemCeilingGiB <n>` 可覆盖。
    static func decodeWindowMemCeilingGiB() -> Int {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeMemCeilingGiB"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]), v > 0 {
            return v
        }
        let gib = devicePhysicalGiB()
        if gib >= 13.5 { return 11 }
        if gib >= 9.5  { return 6 }
        return 5
    }

    /// 阈值 9.5 的来历：设备上报的物理内存略小于标称（16 GB iPad 报 15.14 GiB、
    /// 8 GB iPhone 报 7.45 GiB），用整数会把两台都误判到下一档。
    static func isSmallMemoryDevice() -> Bool {
        devicePhysicalGiB() < 9.5
    }

    /// 本机物理内存（GiB），统一走这里以免各处阈值不一致。
    static func devicePhysicalGiB() -> Double {
        Double(MBDeviceMemoryProbe.physicalBytes) / 1_073_741_824.0
    }

    /// 窗口之外必须留下的常驻量（MiB），可用 `-moeMemReserveMiB <n>` 覆盖。
    /// 实测分解：baseline 0.24 + mmproj 1.21 + MTL0 compute 0.54 + recurrent 0.06
    /// + KV/其它 0.15 ⇒ 约 2.20 GiB。mmap 下非专家权重不计；nommap 额外扣 1.6 GiB。
    /// 见 Comni/v47/ios-app-调优参数与实测.md §6.3。
    static func decodeWindowMemReserveMiB() -> Int {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeMemReserveMiB"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]), v > 0 {
            return v
        }
    // 2400 是基线预留，另加按实际 n_ctx 算出的 KV 增量（不再为没配置的上下文白扣）。
    // 默认 n_ctx=4096 时增量为 40（4k 的 80 MiB 减掉基线已含的 2k 部分 40 MiB）。
        return 2400 + decodeWindowKv32kExtraMiB()
    }

    /// 按实际 n_ctx 算出的、超出基线那部分的 KV 预留（MiB）。
    ///
    /// V47 只有 10 层带 KV（layer 3/7/11/…/39），其余 30 层是 recurrent、不吃 KV，
    /// 实测 40 MiB / 2048 token = 20 KiB/token。2400 那笔已含 2k 基线 KV，这里只返回增量。
    static func decodeWindowKv32kExtraMiB() -> Int {
        let nCtx = defaultNCtx                       // V47 加载就是用这个值
        let kvMiB = Int((Double(nCtx) * 20_480.0 / 1_048_576.0).rounded())  // 20 KiB/token
        let baseline = 40                            // 2400 那笔已含的 2k KV
        return max(0, kvMiB - baseline)
    }

    /// DSpark 开启时额外要预留的常驻量（MiB）—— 草稿模型本体 + 它的 context。
    ///
    /// 实测分解：草稿权重 394.47 + KV 20.00 + compute 122.16 + 其它 ≈ 556 MiB，取 600。
    /// 必须单独算：草稿在 init 时就建（否则草稿 KV 吃不到 prompt），而 mmproj 到开场
    /// prefill 结束才卸载，两者在峰值时刻必然同时驻留。
    /// `-moeDsparkReserveMiB <n>` 可覆盖（传 0 可关掉这笔，用于对照实验）。
    static func decodeWindowDsparkReserveMiB() -> Int {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeDsparkReserveMiB"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]), v >= 0 {
            return v
        }
        return specDraftNMaxResolved() > 0 ? 600 : 0
    }

    /// 预读暂存区每层的 slot 数。与 lookaheadPrefetchDepth() 一致，
    /// 预读关闭时为 0（此时窗口只有缓存区）。
    static func decodeWindowPrefetchSlots() -> Int {
        lookaheadPrefetchDepth()
    }

    /// 每个 expert slot 占多少字节 = 该层 4 个 family 的 bytes_per_expert 之和。
    /// 从 manifest 读，避免把量化档位硬编码。
    private static func bytesPerSlot(at expertsURL: URL) -> Int64? {
        let routed: Set<String> = ["ffn_gate_exps", "ffn_up_exps", "ffn_down_exps", "ffn_gate_up_exps"]
        let manifestURL = expertsURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return nil }
        // 每个 family 取**各层平均** bytes_per_expert（各 family 之间互不重叠，求和即一个 slot）。
        //
        // 不能只看 layer 0：V47 的 down 有一半层是 Q6_K（860160 B）、一半是 Q4_K（589824 B），
        // 只看 layer 0 会高估 ~15%，反推出偏小的 c —— 实测会给出 c=48 而不是最优的 56。
        var perFamily: [String: (sum: Int64, n: Int64)] = [:]
        for e in entries {
            guard let fam = e["tensor_family"] as? String, routed.contains(fam) else { continue }
            let b = jsonInt64(e["bytes_per_expert"])
            guard b > 0 else { continue }
            var cur = perFamily[fam] ?? (0, 0)
            cur.sum += b
            cur.n += 1
            perFamily[fam] = cur
        }
        var total: Int64 = 0
        for (_, v) in perFamily where v.n > 0 {
            total += v.sum / v.n
        }
        return total > 0 ? total : nil
    }

    /// p8d8：prefill / decode 都用 top-8，与 checkpoint / experts 的训练 K 一致。
    /// K=4（p4d4）在 Mac 上约快 1.6x，但会改变采样轨迹，**不是精度无损**；
    /// 真机 K=2 完全不可用（见 logs/newmodel_v47/quality/ANALYSIS.md）。
    ///
    /// ⚠️ 这两个常量目前**没有任何使用者**：真正生效的默认值在
    /// `MTMDWrapper/Bridge/MBMtmd.mm` 的 `MB_MOE_K_PREFILL` / `MB_MOE_K_DECODE`。
    /// 这里保留同名常量只为对照，改 K 时**必须两处一起改**，否则只有一边生效。
    static let moeKPrefill = 8
    static let moeKDecode = 8
    static let lookaheadPrefetchDepthDefaultsKey = "moe_lookahead_prefetch_depth"
    /// 冷启动默认 4（预读下一层 top-4 专家）。本次进程里滑条改的值不写盘。
    ///
    /// 速度上是中性的：曾以为 K=4 快 12%，那是测量陷阱 —— `decodeWindow()` 会扣掉
    /// kSlots 再按 8 取整，K 大的那档缓存反而更小，差的是缓存宽度。详见文档 §9。
    static let defaultLookaheadPrefetchDepth = 8
    static let minLookaheadPrefetchDepth = 0
    static let maxLookaheadPrefetchDepth = 16

    static func maxUbatch(forSlotBank bank: Int) -> Int {
        if bank >= maxSlotBank {
            return defaultNUbatch
        }
        return max(1, bank / 8)
    }

    /// 只在本次进程内有效。冷启动用 `defaultSlotBank`（256，层间共用），不写 UserDefaults。
    private static var sessionSlotBank = defaultSlotBank
    private static let clearPersistedSlotBank: Void = {
        UserDefaults.standard.removeObject(forKey: slotBankDefaultsKey)
    }()
    private static var sessionLookaheadPrefetchDepth = defaultLookaheadPrefetchDepth
    private static let clearPersistedLookaheadPrefetchDepth: Void = {
        UserDefaults.standard.removeObject(forKey: lookaheadPrefetchDepthDefaultsKey)
    }()

    struct Artifacts {
        let modelURL: URL
        let mmprojURL: URL
        let expertsURL: URL
    }

    static func clampSlotBank(_ raw: Int) -> Int {
        let stepped = Int((Double(raw) / Double(slotBankStep)).rounded()) * slotBankStep
        return min(max(stepped, minSlotBank), maxSlotBank)
    }

    static func slotBank() -> Int {
        // 启动参数 `-moeSlotBank N` 覆盖，供基准/内存预算扫描用。
        // 与 lookaheadPrefetchDepth 同理由：手拨 UI 滑条不可复现，
        // 而内存预算实验要求精确控制 bank 值。
        //
        // 注意这里**不走 maxSlotBank 那个 clamp**：那个值（256 = expert_count）是给
        // UI 滑条用的产品上限，而内存预算实验要探到引擎真正允许的上限
        // （`bank <= 32 × n_moe_layers` = 1280）。走 clamp 的话传 512 会被静默夹回 256。
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-moeSlotBank"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let v = Int(ProcessInfo.processInfo.arguments[i + 1]) {
            return max(1, v)
        }
        _ = clearPersistedSlotBank
        return sessionSlotBank
    }

    static func setSlotBank(_ raw: Int) {
        _ = clearPersistedSlotBank
        sessionSlotBank = clampSlotBank(raw)
    }

    static func clampLookaheadPrefetchDepth(_ raw: Int) -> Int {
        min(max(raw, minLookaheadPrefetchDepth), maxLookaheadPrefetchDepth)
    }

    /// 启动参数覆盖，供自动化基准用：`-moeLookaheadDepth N`。
    ///
    /// 必须走启动参数而不是环境变量 —— C 桥的 `apply_lookahead_prefetch_env`
    /// 会用 `setenv(..., 1)` 无条件覆盖环境变量，所以从 `devicectl` 传进去的
    /// 环境变量在 init 时会被冲掉。启动参数在 Swift 层先落地，桥接层再读这里
    /// 的值去 setenv，链路才成立。
    private static let launchArgLookaheadDepth: Int? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-moeLookaheadDepth"), i + 1 < args.count else {
            return nil
        }
        return Int(args[i + 1])
    }()

    static func lookaheadPrefetchDepth() -> Int {
        // 预读 slot 计入窗口宽度（usable = c + K），预算不变时 c 变小；回到 8 GB 机器时
        // 要重新评估这一点（调大 reserve 或降低 `-moeDecodeWindow`，而不是把 K 归零）。
        if let v = launchArgLookaheadDepth {
            return clampLookaheadPrefetchDepth(v)
        }
        _ = clearPersistedLookaheadPrefetchDepth
        return sessionLookaheadPrefetchDepth
    }

    static func setLookaheadPrefetchDepth(_ raw: Int) {
        _ = clearPersistedLookaheadPrefetchDepth
        sessionLookaheadPrefetchDepth = clampLookaheadPrefetchDepth(raw)
    }

    /// 手动把 experts manifest 里 layer≥40 剥掉的老逻辑已随 MTP 一起删除：
    /// 35a3_hf_v47 的 checkpoint 不带 mtp 权重，experts 只有 blk.0–39。

    private static func jsonInt64(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let i = Int64(s) { return i }
        return 0
    }

    struct ExpertsProblem {
        let file: String
        let tensor: String
        let required: Int64
        let actual: Int64

        var text: String {
            actual < 0
                ? "\(file) 缺失（需要 \(required) 字节）"
                : "\(file) 不完整（\(actual)/\(required) 字节，\(tensor)）"
        }
    }

    /// 复刻 llama-moe-experts.cpp 的尺寸校验：manifest 里每个 routed bin 都必须够长。
    /// 手机上下载被截断过，llama 只会抛一句「too small for tensor」，这里提前查出来。
    static func expertsProblems(at expertsURL: URL) -> [ExpertsProblem] {
        let routed: Set<String> = ["ffn_gate_exps", "ffn_up_exps", "ffn_down_exps", "ffn_gate_up_exps"]
        let manifestURL = expertsURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            return [ExpertsProblem(file: "manifest.json", tensor: "-", required: 0, actual: -1)]
        }
        let modelExperts = jsonInt64((root["model"] as? [String: Any])?["expert_count"])

        var required: [String: (bytes: Int64, tensor: String)] = [:]
        for entry in entries {
            guard let family = entry["tensor_family"] as? String, routed.contains(family),
                  let file = entry["repacked_file"] as? String else { continue }
            let declared = jsonInt64(entry["expert_count"])
            let experts = declared > 0 ? declared : modelExperts
            guard experts > 0 else { continue }
            let familyEnd = jsonInt64(entry["repacked_offset"]) + jsonInt64(entry["bytes_per_expert"])
            let need = (experts - 1) * jsonInt64(entry["expert_stride"]) + familyEnd
            if let existing = required[file], existing.bytes >= need { continue }
            required[file] = (need, (entry["tensor_name"] as? String) ?? file)
        }

        var problems: [ExpertsProblem] = []
        for (file, info) in required.sorted(by: { $0.key < $1.key }) {
            let path = expertsURL.appendingPathComponent(file)
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? nil
            let actual = size ?? -1
            if actual < info.bytes {
                problems.append(ExpertsProblem(file: file, tensor: info.tensor, required: info.bytes, actual: actual))
            }
        }
        return problems
    }

    static func resolveArtifacts(in documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) -> Artifacts? {
        return resolveArtifacts(in: documentsDirectory, requireMMProj: true)
    }

    /// `requireMMProj=false` 用于纯文本基准路径（`-moeTextOnly`）：
    /// 那条路只用 model + experts，不需要 1.04GB 的视觉塔。
    /// 正常启动一律走 `requireMMProj=true`，行为与原来完全一致。
    static func resolveArtifacts(in documentsDirectory: URL, requireMMProj: Bool) -> Artifacts? {
        let roots = [
            documentsDirectory.appendingPathComponent(documentsDirName),
            documentsDirectory
        ]
        let fm = FileManager.default
        // 允许启动参数覆盖，便于同一台设备上并存多份量化做 A/B（见 modelFileNameResolved）。
        let modelName = modelFileNameResolved()
        let expertsName = expertsDirNameResolved()
        for root in roots {
            let model = root.appendingPathComponent(modelName)
            let mmproj = root.appendingPathComponent(mmprojFileName)
            let experts = root.appendingPathComponent(expertsName)
            var isDir: ObjCBool = false
            let mmprojOK = !requireMMProj || fm.fileExists(atPath: mmproj.path)
            if fm.fileExists(atPath: model.path),
               mmprojOK,
               fm.fileExists(atPath: experts.path, isDirectory: &isDir), isDir.boolValue {
                print("[MODEL] resolved model=\(modelName) experts=\(expertsName) root=\(root.lastPathComponent)")
                return Artifacts(modelURL: model, mmprojURL: mmproj, expertsURL: experts)
            }
        }
        return nil
    }

    static var copyInstructions: String {
        """
        模型文件需放在 App Documents 下的 \(documentsDirName)/ 目录：
        \(documentsDirName)/\(modelFileName)
        \(documentsDirName)/\(mmprojFileName)
        \(documentsDirName)/experts/manifest.json + layer_000.bin … layer_039.bin
        """
    }}
