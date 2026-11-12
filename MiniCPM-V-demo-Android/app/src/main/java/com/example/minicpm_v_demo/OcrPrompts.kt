package com.example.minicpm_v_demo

/**
 * Per-label prompts copied from iOS OcrDefaultPrompts.
 * chart / seal wording is part of the training data and must not change.
 */
data class OcrElementPrompt(
    val prompt: String,
    val maxTokens: Int,
    val outputFormat: String,
    val skip: Boolean = false,
)

object OcrPrompts {
    val defaultPrompt = OcrElementPrompt("Text Recognition:", 8192, "text")

    private val elementPrompts = mapOf(
        "text" to OcrElementPrompt("Text Recognition:", 4096, "text"),
        "content" to OcrElementPrompt("Text Recognition:", 4096, "text"),
        "abstract" to OcrElementPrompt("Text Recognition:", 4096, "text"),
        "reference" to OcrElementPrompt("Text Recognition:", 2048, "text"),
        "reference_content" to OcrElementPrompt("Text Recognition:", 2048, "text"),
        "vertical_text" to OcrElementPrompt("Text Recognition:", 2048, "text"),
        "vision_footnote" to OcrElementPrompt("Text Recognition:", 1024, "text"),
        "algorithm" to OcrElementPrompt("Text Recognition:", 4096, "text"),
        "doc_title" to OcrElementPrompt("Text Recognition:", 512, "text"),
        "paragraph_title" to OcrElementPrompt("Text Recognition:", 512, "text"),
        "figure_title" to OcrElementPrompt("Text Recognition:", 512, "text"),
        "table" to OcrElementPrompt("Table Recognition:", 8192, "html"),
        "display_formula" to OcrElementPrompt("Formula Recognition:", 2048, "latex"),
        "inline_formula" to OcrElementPrompt("Text Recognition:", 1024, "latex"),
        "formula_number" to OcrElementPrompt("Text Recognition:", 256, "text"),
        "header" to OcrElementPrompt("Text Recognition:", 512, "text"),
        "footer" to OcrElementPrompt("Text Recognition:", 512, "text"),
        "footnote" to OcrElementPrompt("Text Recognition:", 1024, "text"),
        "aside_text" to OcrElementPrompt("Text Recognition:", 1024, "text"),
        "number" to OcrElementPrompt("Text Recognition:", 256, "text"),
        "image" to OcrElementPrompt("", 0, "", skip = true),
        "header_image" to OcrElementPrompt("", 0, "", skip = true),
        "footer_image" to OcrElementPrompt("", 0, "", skip = true),
        "chart" to OcrElementPrompt("Chart to Table:", 4096, "html"),
        "seal" to OcrElementPrompt("Seal Recognition:", 256, "text"),
    )

    val labelIdToName = mapOf(
        0 to "abstract",
        1 to "algorithm",
        2 to "aside_text",
        3 to "chart",
        4 to "content",
        5 to "display_formula",
        6 to "doc_title",
        7 to "figure_title",
        8 to "footer",
        9 to "footer_image",
        10 to "footnote",
        11 to "formula_number",
        12 to "header",
        13 to "header_image",
        14 to "image",
        15 to "inline_formula",
        16 to "number",
        17 to "paragraph_title",
        18 to "reference",
        19 to "reference_content",
        20 to "seal",
        21 to "table",
        22 to "text",
        23 to "vertical_text",
        24 to "vision_footnote",
    )

    val ignoreLabels = setOf("number", "footnote", "header", "footer", "aside_text")

    val titleFormat = mapOf(
        "doc_title" to "# {content}",
        "paragraph_title" to "## {content}",
        "figure_title" to "*{content}*",
    )

    val formulaFormat = mapOf(
        "display_formula" to "$$\n{content}\n$$",
        "inline_formula" to "\${content}$",
    )

    fun promptFor(label: String): OcrElementPrompt = elementPrompts[label] ?: defaultPrompt
}
