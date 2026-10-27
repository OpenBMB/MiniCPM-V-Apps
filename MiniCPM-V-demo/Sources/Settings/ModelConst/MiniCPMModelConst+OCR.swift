//
//  MiniCPMModelConst+OCR.swift
//  MiniCPM-V-demo
//
//  MiniCPM-OCR 1.0 model constants (4x vision + PP-DocLayoutV3 layout).
//

import Foundation

extension MiniCPMModelConst {

    // MARK: - MiniCPM-OCR 1.0 text LLM

    /// OCR 主模型文件名
    static let ocr_LLMFileName = "MiniCPM-OCR-1_0-Q4_K_M.gguf"

    /// OCR 主模型显示名
    static let ocr_LLMDisplayedName = "OCR LLM Q4_K_M"

    /// OCR 主模型下载地址（HuggingFace 主源）
    static let ocr_LLMURLString = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-Q4_K_M.gguf"

    /// OCR 主模型备用下载地址（ModelScope 国内镜像，HF 不通时由 MBModelDownloadHelperV2 自动 fallback）
    static let ocr_LLMBackUpURLString = "https://modelscope.cn/api/v1/models/zerg13/MiniCPM-V-Apps-gguf/repo?Revision=master&FilePath=MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-Q4_K_M.gguf"

    /// OCR 主模型 MD5
    static let ocr_LLMMD5 = "4f8f6f58429dc9a584c70c490a120dfd"


    // MARK: - MiniCPM-OCR 1.0 mmproj vision encoder (4x downsample)

    /// OCR mmproj 文件名
    static let ocr_MMProjFileName = "MiniCPM-OCR-1_0-mmproj-F16-4x.gguf"

    /// OCR mmproj 显示名
    static let ocr_MMProjDisplayedName = "OCR VPM (4x)"

    /// OCR mmproj 下载地址（HuggingFace 主源）
    static let ocr_MMProjURLString = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-mmproj-F16-4x.gguf"

    /// OCR mmproj 备用下载地址（ModelScope 国内镜像）
    static let ocr_MMProjBackUpURLString = "https://modelscope.cn/api/v1/models/zerg13/MiniCPM-V-Apps-gguf/repo?Revision=master&FilePath=MiniCPM-OCR-1.0/MiniCPM-OCR-1_0-mmproj-F16-4x.gguf"

    /// OCR mmproj MD5
    static let ocr_MMProjMD5 = "5dc7d0b598700f10581bbbcc0e420056"


    // MARK: - PP-DocLayoutV3 layout detector (ONNX)

    /// PP-DocLayoutV3 ONNX 文件名
    static let ocr_LayoutFileName = "PPDocLayoutV3_fix4.onnx"

    /// PP-DocLayoutV3 显示名
    static let ocr_LayoutDisplayedName = "PP-DocLayoutV3 Layout"

    /// PP-DocLayoutV3 下载地址（HuggingFace 主源）
    static let ocr_LayoutURLString = "https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf/resolve/main/MiniCPM-OCR-1.0/PPDocLayoutV3_fix4.onnx"

    /// PP-DocLayoutV3 备用下载地址（ModelScope 国内镜像）
    static let ocr_LayoutBackUpURLString = "https://modelscope.cn/api/v1/models/zerg13/MiniCPM-V-Apps-gguf/repo?Revision=master&FilePath=MiniCPM-OCR-1.0/PPDocLayoutV3_fix4.onnx"

    /// PP-DocLayoutV3 ONNX MD5
    static let ocr_LayoutMD5 = "d1a03f12240c5ae0cad14155e6c2c41b"


    // MARK: - Display name

    /// OCR 模型整体显示名（设置页列表条目）
    static let ocr_DisplayedName = "MiniCPM-OCR 1.0"

    /// 旧版 OCR 文件名，启动时清掉，避免白占 1.4 GB。
    /// 改名前的两份权重是上一代 ckpt 转的，内容与当前不一致，不能复用。
    static let ocr_StaleFileNames = [
        "MiniCPM-V-4_6-OCR-Q4_K_M.gguf",
        "MiniCPM-V-4_6-OCR-mmproj-F16.gguf",
    ]

    /// 删除 `ocr_StaleFileNames` 列出的文件。没有则静默返回。
    static func removeStaleOcrFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ocr_StaleFileNames {
            let url = docs.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                print("[MODEL] 已删除旧 OCR 文件 \(name)")
            } catch {
                print("[MODEL] 删除旧 OCR 文件 \(name) 失败：\(error)")
            }
        }
    }
}
