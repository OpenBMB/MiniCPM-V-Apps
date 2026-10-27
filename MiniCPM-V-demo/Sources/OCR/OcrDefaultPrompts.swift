//
//  OcrDefaultPrompts.swift
//  MiniCPM-V-demo
//
//  OCR prompt configuration.
//  24 layout labels, each with a prompt, token limit, and output format.
//  image, header_image and footer_image are crop-only: they never reach the model.
//

import Foundation

/// Per-label OCR configuration
struct OcrElementPrompt: Sendable {
    let prompt: String
    let maxTokens: Int
    let outputFormat: String   // "text" | "html" | "latex"
    let skip: Bool             // true = don't send to VLM (image, seal, etc.)

    init(prompt: String, maxTokens: Int, outputFormat: String, skip: Bool = false) {
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.outputFormat = outputFormat
        self.skip = skip
    }
}

/// OCR prompt map
enum OcrDefaultPrompts {
    // Default fallback (used when label not in elementPrompts)
    static let defaultPrompt = OcrElementPrompt(
        prompt: "Text Recognition:", maxTokens: 8192, outputFormat: "text"
    )

    // 24 label types with per-label settings
    static let elementPrompts: [String: OcrElementPrompt] = [
        "text":             OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 4096, outputFormat: "text"),
        "content":          OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 4096, outputFormat: "text"),
        "abstract":         OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 4096, outputFormat: "text"),
        "reference":        OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 2048, outputFormat: "text"),
        "reference_content":OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 2048, outputFormat: "text"),
        "vertical_text":    OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 2048, outputFormat: "text"),
        "vision_footnote":  OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 1024, outputFormat: "text"),
        "algorithm":        OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 4096, outputFormat: "text"),
        "doc_title":        OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 512,  outputFormat: "text"),
        "paragraph_title":  OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 512,  outputFormat: "text"),
        "figure_title":     OcrElementPrompt(prompt: "Text Recognition:", maxTokens: 512,  outputFormat: "text"),
        "table":            OcrElementPrompt(prompt: "Table Recognition:",  maxTokens: 8192, outputFormat: "html"),
        "display_formula":  OcrElementPrompt(prompt: "Formula Recognition:", maxTokens: 2048, outputFormat: "latex"),
        "inline_formula":   OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 1024, outputFormat: "latex"),
        "formula_number":   OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 256,  outputFormat: "text"),
        "header":           OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 512,  outputFormat: "text"),
        "footer":           OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 512,  outputFormat: "text"),
        "footnote":         OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 1024, outputFormat: "text"),
        "aside_text":       OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 1024, outputFormat: "text"),
        "number":           OcrElementPrompt(prompt: "Text Recognition:",   maxTokens: 256,  outputFormat: "text"),
        "image":            OcrElementPrompt(prompt: "", maxTokens: 0, outputFormat: "", skip: true),
        "header_image":     OcrElementPrompt(prompt: "", maxTokens: 0, outputFormat: "", skip: true),
        "footer_image":     OcrElementPrompt(prompt: "", maxTokens: 0, outputFormat: "", skip: true),
        // chart / seal 的 prompt 必须和训练数据一字不差。chart 用 "Table Recognition:"
        // 会臆造表头，seal 用 "Text Recognition:" 会出乱码。
        "chart":            OcrElementPrompt(prompt: "Chart to Table:",   maxTokens: 4096, outputFormat: "html"),
        "seal":             OcrElementPrompt(prompt: "Seal Recognition:", maxTokens: 256,  outputFormat: "text"),
    ]

    // Label IDs (0-24) to label names
    static let labelIdToName: [Int: String] = [
        0:  "abstract",
        1:  "algorithm",
        2:  "aside_text",
        3:  "chart",
        4:  "content",
        5:  "display_formula",
        6:  "doc_title",
        7:  "figure_title",
        8:  "footer",
        9:  "footer_image",
        10: "footnote",
        11: "formula_number",
        12: "header",
        13: "header_image",
        14: "image",
        15: "inline_formula",
        16: "number",
        17: "paragraph_title",
        18: "reference",
        19: "reference_content",
        20: "seal",
        21: "table",
        22: "text",
        23: "vertical_text",
        24: "vision_footnote",
    ]

    /// Get element prompt for a layout label; falls back to defaultPrompt.
    static func promptFor(label: String) -> OcrElementPrompt {
        return elementPrompts[label] ?? defaultPrompt
    }

    // MARK: - Markdown Assembly

    /// Labels ignored during markdown assembly (don't appear in final output).
    static let ignoreLabels: Set<String> = [
        "number", "footnote", "header", "footer", "aside_text"
    ]

    /// Title formatting rules.
    static let titleFormat: [String: String] = [
        "doc_title":       "# {content}",
        "paragraph_title": "## {content}",
        "figure_title":    "*{content}*",
    ]

    /// Formula formatting rules.
    static let formulaFormat: [String: String] = [
        "display_formula": "$$\n{content}\n$$",
        "inline_formula":  "${content}$",
    ]

    /// Format patterns applied in assembleMarkdown().
    static let tableFormat = "{content}"
    static let chartFormat = "{content}"
    static let sealFormat  = "{content}"
}
