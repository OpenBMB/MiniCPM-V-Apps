package com.example.minicpm_v_demo

/**
 * Prepares OCR markdown for Markwon's LaTeX extension.
 *
 * The extension's inline math processor matches `(\${2})([\s\S]+?)\1` -- double
 * dollars only. OCR output is almost entirely single-`$` (`$G = mg$`), so
 * without this pass every formula would stay literal text.
 *
 * Existing `$$...$$` blocks are protected first: their delimiters must not be
 * rewritten, and the formulas between them must not be scanned for `$` pairs.
 *
 * Display-only. The markdown handed to the user (and to any exporter) has to
 * stay standard, so this runs at render time and never mutates the output of
 * [OcrMarkdown.assemble].
 */
object OcrLatexMarkdown {

    /** Placeholder standing in for one protected `$$...$$` block. */
    private const val BLOCK_OPEN = "\u0001BO\u0001"
    private const val BLOCK_CLOSE = "\u0001BC\u0001"

    /** `$...$` with no `$` or newline inside. */
    private val singleDollar = Regex("""\$([^$\n]+?)\$""")

    fun prepare(markdown: String): String {
        if (markdown.isEmpty() || !markdown.contains('$')) return markdown

        // Pass 1: lift `$$...$$` blocks out of the way.
        val blocks = ArrayList<String>()
        val masked = StringBuilder()
        var cursor = 0
        while (true) {
            val open = markdown.indexOf("$$", cursor)
            if (open < 0) break
            val close = markdown.indexOf("$$", open + 2)
            if (close < 0) break
            masked.append(markdown, cursor, open)
            masked.append(BLOCK_OPEN).append(blocks.size).append(BLOCK_CLOSE)
            blocks.add(markdown.substring(open + 2, close))
            cursor = close + 2
        }
        masked.append(markdown, cursor, markdown.length)

        // Pass 2: single-$ pairs become double-$ pairs.
        var body = singleDollar.replace(masked.toString()) { m -> "$$" + m.groupValues[1] + "$$" }

        // Pass 3: put the original blocks back, unchanged.
        for ((index, latex) in blocks.withIndex()) {
            body = body.replace(BLOCK_OPEN + index + BLOCK_CLOSE, "$$" + latex + "$$")
        }
        return body
    }
}
