package com.example.minicpm_v_demo

/**
 * Crop cleanup and markdown assembly. Follows iOS OcrMarkdownUtils,
 * including OTSL tables and the LaTeX repair chain.
 */
object OcrMarkdown {
    data class Block(
        val label: String,
        val content: String,
        val order: Int,
        val inlineFormulaMixed: Boolean = false,
    )

    private val textBlockLabels = setOf(
        "text", "content", "abstract", "reference", "reference_content",
        "vertical_text", "vision_footnote", "algorithm", "header", "footer",
        "footnote", "aside_text",
    )
    private val failureMarkers = listOf(
        "failed", "cuda out of memory", "outofmemoryerror", "enginecore", "traceback",
    )
    private val commentRE = Regex("""^\s*<!--\s*(.*?)\s*-->\s*$""", RegexOption.DOT_MATCHES_ALL)
    private val inlineMathRE = Regex("""(?<!\\)\$(?!\$)(?:[^$\n]|\\.)+?(?<!\\)\$(?!\$)|\\\([^\n]*?\\\)""")

    fun classifyEngineText(raw: String): String {
        val match = commentRE.matchEntire(raw) ?: return raw
        val msg = match.groupValues[1].trim().lowercase()
        if (failureMarkers.any { msg.contains(it) }) return ""
        return raw
    }

    fun hasMixedInlineFormula(content: String): Boolean {
        val stripped = content.trim()
        if (stripped.isEmpty()) return false
        if (inlineMathRE.matchEntire(stripped) != null) return false
        val without = inlineMathRE.replace(stripped, "")
        return without.trim().isNotEmpty()
    }

    fun postprocess(raw: String, outputFormat: String, label: String): String {
        var content = truncateRepetitive(raw.trim(), if (label == "table") 5000 else 50)
        if (outputFormat == "latex") {
            if (label == "display_formula") content = repairDisplayDollars(content)
            content = content.replace(Regex("""\\\[\s*\\\]|\\\(\s*\\\)"""), " ")
            for ((open, close) in listOf("$$" to "$$", "$" to "$", "\\(" to "\\)", "\\[" to "\\]")) {
                if (content.startsWith(open) && content.endsWith(close) && content.length >= open.length + close.length) {
                    content = content.substring(open.length, content.length - close.length).trim()
                }
            }
            if (label == "display_formula") {
                // Regex replacement strings treat `$` as a group reference, so
                // passing "$$   $$" literally through the pattern overload
                // expands "$$" to a single "$" (or, for a bare "$", throws
                // "Illegal group reference"). quoteReplacement suppresses
                // that so the separator survives verbatim.
                content = content.replaceFirst(
                    Regex("""\\]\s*\\\["""),
                    java.util.regex.Matcher.quoteReplacement("$$   $$"),
                )
                content = content.replace("\\[", "").replace("\\]", "")
            }
            if (label == "display_formula" || label == "inline_formula") {
                content = OcrLatexRepair.repair(content, label)
            }
        } else if (outputFormat == "html") {
            if (content.startsWith("```html")) content = content.drop(7)
            if (content.startsWith("```")) content = content.drop(3)
            if (content.endsWith("```")) content = content.dropLast(3)
            content = content.trim()
            if (label == "table") {
                val openCount = Regex("<table").findAll(content).count()
                val closeCount = Regex("</table>").findAll(content).count()
                if (openCount > closeCount) content += "</table>".repeat(openCount - closeCount)
            }
        }
        return content
    }

    fun normalize(blocks: List<Block>): List<Block> {
        val seen = HashSet<String>()
        val out = ArrayList<Block>()
        for (block in blocks.sortedBy { it.order }) {
            var content = truncateSuffix(block.content.trim())
            if (block.label != "display_formula") {
                content = Regex("""\\\((.+?)\\\)""").replace(content) { m ->
                    "$${m.groupValues[1].trim()}$"
                }
            } else {
                content = content.replace(Regex("""\\]\s*\\\["""), "$$   $$")
                content = content.replace("\\[", "").replace("\\]", "")
            }
            content = Regex("""[ \t]+""").replace(content, " ")
            content = Regex("""\n{3,}""").replace(content, "\n\n")
            if (block.label == "table" || block.label == "chart") {
                val html = OcrOtsl.convert(content)
                if (html.isNotEmpty()) content = html
            }
            if (block.label in textBlockLabels) content = splitText(content, false)
            else if (block.label == "inline_formula" && block.inlineFormulaMixed) content = splitText(content, true)
            val key = "${block.order}|${block.label}|$content"
            if (!seen.add(key)) continue
            out.add(block.copy(content = content))
        }
        return out
    }

    fun assemble(blocks: List<Block>): String {
        val imageLabels = setOf("image", "header_image", "footer_image")
        val parts = ArrayList<String>()
        for (block in blocks.sortedBy { it.order }) {
            val label = block.label
            val content = block.content
            if (label in OcrPrompts.ignoreLabels) continue
            if (content.isEmpty() && label !in imageLabels && label != "chart" && label != "seal") continue
            val title = OcrPrompts.titleFormat[label]
            val formula = OcrPrompts.formulaFormat[label]
            when {
                title != null -> parts.add(title.replace("{content}", content))
                formula != null -> {
                    if (label == "inline_formula" && block.inlineFormulaMixed) parts.add(content)
                    else parts.add(formula.replace("{content}", content))
                }
                label in imageLabels -> parts.add("![image]()")
                label == "chart" || label == "seal" -> {
                    parts.add(if (content.isEmpty()) "![image]()" else content)
                }
                else -> parts.add(content)
            }
        }
        return parts.joinToString("\n\n")
    }

    private fun truncateRepetitive(content: String, minCount: Int): String {
        if (content.isEmpty() || content.length < minCount) return content
        val stripped = content.trim()
        if (stripped.isEmpty()) return content
        if (!stripped.contains('\n') && stripped.length > 100) {
            val n = stripped.length
            val upper = n / 5
            if (upper >= 8) {
                for (unitLen in 8..upper) {
                    val unit = stripped.substring(n - unitLen)
                    var count = 0
                    var pos = n - unitLen
                    while (pos >= 0 && stripped.substring(pos, pos + unitLen) == unit) {
                        count += 1
                        pos -= unitLen
                    }
                    if (count >= 5 && unit.length * count > n * 0.5) {
                        return stripped.substring(0, n - count * unitLen)
                    }
                }
            }
        }
        return content
    }

    private fun truncateSuffix(text: String): String {
        val words = Regex("""\S+""").findAll(text).map { it.value.lowercase() to it.range.first }.toList()
        if (words.size < 18) return text
        var earliest = text.length
        val maxWindow = minOf(64, words.size / 3)
        if (maxWindow >= 6) {
            for (window in 6..maxWindow) {
                val limit = words.size - window * 3 + 1
                if (limit <= 0) continue
                for (start in 0 until limit) {
                    val first = words.subList(start, start + window).map { it.first }
                    val second = words.subList(start + window, start + window * 2).map { it.first }
                    val third = words.subList(start + window * 2, start + window * 3).map { it.first }
                    if (first == second && first == third) {
                        earliest = minOf(earliest, words[start].second)
                        break
                    }
                }
            }
        }
        return if (earliest < text.length) text.substring(0, earliest).trimEnd() else text
    }

    private fun splitText(content: String, protectInlineMath: Boolean): String {
        val lines = content.split('\n')
        val output = ArrayList<String>()
        for (line in lines) {
            val stripped = line.trim()
            if (stripped.isEmpty()) continue
            if (output.isNotEmpty() && output.last().isNotBlank()) output.add("")
            output.add(if (protectInlineMath) line else stripped)
            output.add("")
        }
        return output.joinToString("\n").replace(Regex("""\n{3,}"""), "\n\n").trim('\n')
    }

    private fun repairDisplayDollars(markdown: String): String {
        val tokens = ArrayList<String>()
        var rest = markdown
        while (true) {
            val at = rest.indexOf("$$")
            if (at < 0) break
            tokens.add(rest.substring(0, at))
            tokens.add("$$")
            rest = rest.substring(at + 2)
        }
        tokens.add(rest)
        val output = ArrayList<String>()
        var inDisplay = false
        for (index in tokens.indices) {
            val token = tokens[index]
            if (token != "$$") {
                output.add(token)
                continue
            }
            val nextSegment = tokens.getOrElse(index + 1) { "" }
            val nextIsDelimiter = index + 2 < tokens.size && tokens[index + 2] == "$$"
            val hasLater = tokens.drop(index + 2).contains("$$")
            if (!inDisplay) {
                if ((nextSegment.isBlank() && nextIsDelimiter) || !hasLater) continue
                output.add(token)
                inDisplay = true
            } else {
                output.add(token)
                inDisplay = false
            }
        }
        if (inDisplay && output.isNotEmpty()) output.removeAt(output.lastIndex)
        return output.joinToString("")
    }
}

/** OTSL (`<fcel>`, `<nl>`, span tags) to an HTML table. */
object OcrOtsl {
    private const val NL = "<nl>"
    private const val FCEL = "<fcel>"
    private const val ECEL = "<ecel>"
    private const val LCEL = "<lcel>"
    private const val UCEL = "<ucel>"
    private const val XCEL = "<xcel>"
    private val tags = setOf(NL, FCEL, ECEL, LCEL, UCEL, XCEL)
    private val tokenRE = Regex("""(<nl>|<fcel>|<ecel>|<lcel>|<ucel>|<xcel>)""")

    fun convert(otsl: String): String {
        if (!otsl.contains("<fcel>") && !otsl.contains("<nl>")) return ""
        val padded = pad(otsl.trim())
        val (tokens, mixed) = extract(padded)
        val (cells, rows) = parse(mixed, tokens)
        if (cells.isEmpty()) return ""
        val cols = rows.maxOfOrNull { it.size } ?: 0
        return export(cells, rows.size, cols)
    }

    private fun pad(otsl: String): String {
        if (!otsl.contains(NL)) return otsl + NL
        val rowData = otsl.split(NL).filter { it.isNotEmpty() }.map { line ->
            val raw = Regex("""(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>).*?(?=(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>)|$)""")
                .findAll(line).map { it.value }.toList()
            var minLen = 0
            for ((i, cell) in raw.withIndex()) if (cell.startsWith(FCEL)) minLen = i + 1
            Triple(raw, raw.size, minLen)
        }
        if (rowData.isEmpty()) return NL
        val globalMin = rowData.maxOf { it.third }
        val maxTotal = rowData.maxOf { it.second }
        var width = maxOf(globalMin, maxTotal)
        var best = Int.MAX_VALUE
        for (w in globalMin..maxOf(globalMin, maxTotal)) {
            val cost = rowData.sumOf { kotlin.math.abs(it.second - w) }
            if (cost < best) {
                best = cost
                width = w
            }
        }
        return rowData.joinToString(NL) { row ->
            val cells = if (row.second > width) row.first.take(width) else row.first + List(width - row.second) { ECEL }
            cells.joinToString("")
        } + NL
    }

    private fun extract(s: String): Pair<List<String>, List<String>> {
        val tokens = tokenRE.findAll(s).map { it.value }.toList()
        val parts = ArrayList<String>()
        var cursor = 0
        for (m in tokenRE.findAll(s)) {
            if (m.range.first > cursor) parts.add(s.substring(cursor, m.range.first))
            parts.add(m.value)
            cursor = m.range.last + 1
        }
        if (cursor < s.length) parts.add(s.substring(cursor))
        return tokens to parts.filter { it.isNotBlank() }
    }

    private fun rowsOf(tokens: List<String>): MutableList<MutableList<String>> {
        val rows = ArrayList<MutableList<String>>()
        var cur = ArrayList<String>()
        var open = false
        for (token in tokens) {
            if (token == NL) {
                if (open) {
                    rows.add(cur)
                    cur = ArrayList()
                    open = false
                }
            } else {
                cur.add(token)
                open = true
            }
        }
        if (open) rows.add(cur)
        return rows
    }

    private data class Cell(val text: String, val row: Int, val col: Int, val rowSpan: Int, val colSpan: Int)

    private fun parse(input: List<String>, tokens: List<String>): Pair<List<Cell>, List<List<String>>> {
        val splitRows = rowsOf(tokens)
        var texts = input
        if (splitRows.isNotEmpty()) {
            val maxCols = splitRows.maxOf { it.size }
            for (row in splitRows) while (row.size < maxCols) row.add(ECEL)
            val rebuilt = ArrayList<String>()
            var textIdx = 0
            for (row in splitRows) {
                for (token in row) {
                    rebuilt.add(token)
                    if (textIdx < texts.size && texts[textIdx] == token) {
                        textIdx += 1
                        if (textIdx < texts.size && texts[textIdx] !in tags) {
                            rebuilt.add(texts[textIdx])
                            textIdx += 1
                        }
                    }
                }
                rebuilt.add(NL)
                if (textIdx < texts.size && texts[textIdx] == NL) textIdx += 1
            }
            texts = rebuilt
        }
        val cells = ArrayList<Cell>()
        var rIdx = 0
        var cIdx = 0
        for ((i, text) in texts.withIndex()) {
            if (text == FCEL || text == ECEL) {
                var rowSpan = 1
                var colSpan = 1
                var rightOffset = 1
                var cellText = ""
                if (text != ECEL) {
                    cellText = texts.getOrElse(i + 1) { "" }
                    rightOffset = 2
                }
                val nextRight = texts.getOrElse(i + rightOffset) { "" }
                val nextBottom = if (rIdx + 1 < splitRows.size && cIdx < splitRows[rIdx + 1].size) {
                    splitRows[rIdx + 1][cIdx]
                } else ""
                if (nextRight == LCEL || nextRight == XCEL) {
                    var span = 0
                    var ci = cIdx + 1
                    while (ci < splitRows[rIdx].size && splitRows[rIdx][ci] in setOf(LCEL, XCEL)) {
                        ci += 1
                        span += 1
                    }
                    colSpan += span
                }
                if (nextBottom == UCEL || nextBottom == XCEL) {
                    var span = 0
                    var ri = rIdx + 1
                    while (ri < splitRows.size && cIdx < splitRows[ri].size && splitRows[ri][cIdx] in setOf(UCEL, XCEL)) {
                        ri += 1
                        span += 1
                    }
                    rowSpan += span
                }
                cells.add(Cell(cellText.trim(), rIdx, cIdx, rowSpan, colSpan))
            }
            if (text in setOf(FCEL, ECEL, LCEL, UCEL, XCEL)) cIdx += 1
            if (text == NL) {
                rIdx += 1
                cIdx = 0
            }
        }
        return cells to splitRows
    }

    private fun export(cells: List<Cell>, rows: Int, cols: Int): String {
        if (cells.isEmpty() || rows == 0 || cols == 0) return ""
        val grid = Array(rows) { r -> Array(cols) { c -> Cell("", r, c, 1, 1) } }
        for (cell in cells) {
            for (i in cell.row until minOf(cell.row + cell.rowSpan, rows)) {
                for (j in cell.col until minOf(cell.col + cell.colSpan, cols)) {
                    grid[i][j] = cell
                }
            }
        }
        val body = StringBuilder()
        for (i in 0 until rows) {
            body.append("<tr>")
            for (j in 0 until cols) {
                val cell = grid[i][j]
                if (cell.row != i || cell.col != j) continue
                val content = htmlEscape(cell.text.trim())
                val span = buildString {
                    if (cell.rowSpan > 1) append(" rowspan=\"${cell.rowSpan}\"")
                    if (cell.colSpan > 1) append(" colspan=\"${cell.colSpan}\"")
                }
                body.append("<td$span>$content</td>")
            }
            body.append("</tr>")
        }
        return "<table>$body</table>"
    }

    private fun htmlEscape(s: String) = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
}

/** LaTeX cleanup from iOS OcrLatexRepair. */
object OcrLatexRepair {
    private val envTypes = listOf(
        "array", "matrix", "pmatrix", "bmatrix", "vmatrix",
        "Bmatrix", "Vmatrix", "cases", "aligned", "gathered", "align", "align*",
    )
    private val leftRE = Regex(
        """(\\left)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[\{\}|.]|[()\[\]\{\}/|.])?"""
    )
    private val rightRE = Regex(
        """(\\right)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[\{\}|.]|[()\[\]\{\}/|.])?"""
    )
    private val leftCountRE = Regex("""\\left(?![a-zA-Z])""")
    private val rightCountRE = Regex("""\\right(?![a-zA-Z])""")
    private val leftRightRemoveRE = Regex("""\\left(?![a-zA-Z])\.?|\\right(?![a-zA-Z])\.?""")

    fun repair(s: String, label: String): String {
        if (s.isBlank()) return s
        var out = fixUnbalancedBraces(s)
        out = fixLeftRight(out, label == "display_formula" || label.isEmpty())
        out = fixEnvironments(out)
        out = out.replace(Regex("""(\\end\{array\}\s*\\right\.\s*){2,}"""), "\\\\end{array} \\\\right.")
        out = out.replace(Regex("""(\\\]\s*){2,}"""), "\\\\]")
        return out.replace(Regex("""\\+$"""), "").trim()
    }

    private fun fixUnbalancedBraces(s: String): String {
        val chars = s.toCharArray()
        val stack = ArrayList<Int>()
        val unmatched = HashSet<Int>()
        for (i in chars.indices) {
            val ch = chars[i]
            if (ch != '{' && ch != '}') continue
            if (escaped(chars, i)) continue
            if (ch == '{') stack.add(i) else if (stack.isEmpty()) unmatched.add(i) else stack.removeAt(stack.lastIndex)
        }
        unmatched.addAll(stack)
        if (unmatched.isEmpty()) return s
        return buildString {
            for (i in chars.indices) if (i !in unmatched) append(chars[i])
        }
    }

    private fun escaped(chars: CharArray, pos: Int): Boolean {
        var count = 0
        var j = pos - 1
        while (j >= 0 && chars[j] == '\\') {
            count += 1
            j -= 1
        }
        return count % 2 == 1
    }

    private fun fixLeftRight(s: String, fixDelimiter: Boolean): String {
        var out = s
        if (fixDelimiter) {
            out = leftRE.replace(out) { m ->
                val delim = m.groupValues.getOrElse(2) { "" }
                if (delim.isEmpty()) m.groupValues[1] + "." else m.value
            }
            out = rightRE.replace(out) { m ->
                val delim = m.groupValues.getOrElse(2) { "" }
                if (delim.isEmpty()) m.groupValues[1] + "." else m.value
            }
        }
        val left = leftCountRE.findAll(out).count()
        val right = rightCountRE.findAll(out).count()
        return if (left == right) out else leftRightRemoveRE.replace(out, "")
    }

    private fun fixEnvironments(s: String): String {
        var out = s
        for (env in envTypes) {
            val begin = Regex("""\\begin\{${Regex.escape(env)}\}""").findAll(out).count()
            val end = Regex("""\\end\{${Regex.escape(env)}\}""").findAll(out).count()
            if (begin == end) continue
            if (end > begin) {
                val fmt = if (env == "array") "{c}" else ""
                out = ("\\begin{$env}$fmt ").repeat(end - begin) + out
            } else {
                out += (" \\end{$env}").repeat(begin - end)
            }
        }
        return out
    }
}
