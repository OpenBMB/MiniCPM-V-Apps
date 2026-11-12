package com.example.minicpm_v_demo

import android.graphics.Canvas
import android.graphics.Paint
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ReplacementSpan
import io.noties.markwon.utils.SpanUtils
import kotlin.math.ceil

/**
 * One OCR table as a grid of cells. Both input shapes -- OTSL that [OcrOtsl]
 * rewrites, and HTML the model emits directly -- arrive as `<table>` markup.
 */
class OcrTable(val rows: List<Row>, val columnCount: Int) {

    class Row(val cells: List<Cell>)

    class Cell(
        val text: String,
        val isHeader: Boolean,
        val colspan: Int,
        val rowspan: Int,
    )
}

/** Minimal `<table>` reader: `<tr>`, `<td>`/`<th>`, colspan, rowspan, entities. */
object OcrHtmlTable {

    private val rowTag = Regex("""<tr\b[^>]*>""", RegexOption.IGNORE_CASE)
    private val cellTag = Regex("""<t([dh])\b([^>]*)>""", RegexOption.IGNORE_CASE)
    private val breakTag = Regex("""<br\b[^>]*>""", RegexOption.IGNORE_CASE)
    private val anyTag = Regex("""<[^>]*>""")
    private val entity = Regex("""&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);""")
    private val whitespace = Regex("""\s+""")

    fun parse(html: String): OcrTable? {
        val opens = rowTag.findAll(html).toList()
        if (opens.isEmpty()) return null

        val occupied = ArrayList<MutableList<Boolean>>()
        val rows = ArrayList<OcrTable.Row>()
        var maxCols = 0

        fun mark(row: Int, col: Int) {
            while (occupied.size <= row) occupied.add(ArrayList())
            val line = occupied[row]
            while (line.size <= col) line.add(false)
            line[col] = true
        }

        fun taken(row: Int, col: Int): Boolean =
            row < occupied.size && col < occupied[row].size && occupied[row][col]

        for ((index, open) in opens.withIndex()) {
            val from = open.range.last + 1
            val to = opens.getOrNull(index + 1)?.range?.first ?: html.length
            var body = html.substring(from, to)
            val closeRow = body.indexOf("</tr>", 0, true)
            if (closeRow >= 0) body = body.substring(0, closeRow)

            val cells = ArrayList<OcrTable.Cell>()
            var col = 0
            var cursor = 0
            while (true) {
                val head = cellTag.find(body, cursor) ?: break
                val isHeader = head.groupValues[1].equals("h", ignoreCase = true)
                val attrs = head.groupValues[2]
                val next = cellTag.find(body, head.range.last + 1)
                var inner = body.substring(head.range.last + 1, next?.range?.first ?: body.length)
                val closeCell = inner.indexOf("</t", 0, true)
                if (closeCell >= 0) inner = inner.substring(0, closeCell)

                val colspan = intAttr(attrs, "colspan")
                val rowspan = intAttr(attrs, "rowspan")
                // Columns already claimed by a rowspan from an earlier row.
                while (taken(rows.size, col)) col++
                for (dr in 0 until rowspan) {
                    for (dc in 0 until colspan) mark(rows.size + dr, col + dc)
                }
                cells.add(OcrTable.Cell(plainText(inner), isHeader, colspan, rowspan))
                maxCols = maxOf(maxCols, col + colspan)
                col += colspan
                cursor = next?.range?.first ?: body.length
            }
            if (cells.isNotEmpty()) rows.add(OcrTable.Row(cells))
        }
        // The model sometimes closes with a row of empty <td>s.
        while (rows.isNotEmpty() && rows.last().cells.all { it.text.isEmpty() }) {
            rows.removeAt(rows.size - 1)
        }

        if (rows.isEmpty() || maxCols == 0) return null
        // The model writes <td> for header rows too, so a <th> test alone never
        // fires. Treat the first row as a header unless it is a lone
        // full-width cell, which is how footnote rows look.
        val first = rows[0].cells
        val firstIsHeader = first.any { it.isHeader } ||
            (rows.size > 1 && first.size > 1 && first.sumOf { it.colspan } == maxCols)
        if (firstIsHeader) {
            rows[0] = OcrTable.Row(first.map { OcrTable.Cell(it.text, true, it.colspan, it.rowspan) })
        }
        return OcrTable(rows, maxCols)
    }

    private fun intAttr(attrs: String, name: String): Int {
        val match = Regex("""\b$name\s*=\s*["']?(\d+)""", RegexOption.IGNORE_CASE).find(attrs)
            ?: return 1
        return match.groupValues[1].toIntOrNull()?.coerceIn(1, 64) ?: 1
    }

    private fun plainText(inner: String): String = decodeEntities(
        inner.replace(breakTag, " ").replace(anyTag, "")
    ).replace('\u00a0', ' ').replace(whitespace, " ").trim()

    private fun decodeEntities(text: String): String = entity.replace(text) { m ->
        val name = m.groupValues[1]
        when {
            name == "amp" -> "&"
            name == "lt" -> "<"
            name == "gt" -> ">"
            name == "quot" -> "\""
            name == "apos" -> "'"
            name == "nbsp" -> "\u00a0"
            name.startsWith("#x") || name.startsWith("#X") ->
                name.drop(2).toIntOrNull(16)?.toChar()?.toString() ?: m.value
            name.startsWith("#") ->
                name.drop(1).toIntOrNull()?.toChar()?.toString() ?: m.value
            else -> m.value
        }
    }
}

/** Colours and metrics for [OcrTableSpan], resolved from the current theme. */
data class OcrTableStyle(
    val textSize: Float,
    val textColor: Int,
    val headerBackground: Int,
    val oddRowBackground: Int,
    val borderColor: Int,
    val cellPadding: Int,
    val borderWidth: Int,
)

/**
 * Draws an [OcrTable] as a grid.
 *
 * Markwon drops `<table>` blocks: a table parses to an `HtmlBlock`, the core
 * visitor has no handler for it, and the node has no children to fall back to.
 * [OcrTableMarkdown] masks tables out of the markdown and puts one of these
 * spans over the placeholder, which keeps colspan/rowspan that a GFM pipe table
 * could not express.
 *
 * The width is only known once the span is drawn ([SpanUtils] reads it off the
 * TextView), so the first measure reports zero height, the draw builds the
 * layout and asks the view to re-measure, and the second pass returns the real
 * metrics -- the same two-pass approach Markwon's own table rows use.
 */
class OcrTableSpan(
    private val table: OcrTable,
    private val style: OcrTableStyle,
    basePaint: TextPaint? = null,
    preferredWidth: Int = 0,
) : ReplacementSpan() {

    private class Slot(
        val row: Int,
        val col: Int,
        val rowSpan: Int,
        val colSpan: Int,
        val layout: StaticLayout,
    )

    private val bodyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val headerPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    private var slots: List<Slot> = emptyList()
    private var colWidths = IntArray(0)
    private var rowHeights = IntArray(0)
    private var contentWidth = 0
    private var contentHeight = 0
    private var measuredWidth = 0

    /** Called when the span has re-measured after finding its width. */
    var invalidator: (() -> Unit)? = null

    init {
        preparePaints(basePaint)
        if (preferredWidth > 0) measure(preferredWidth)
    }

    override fun getSize(
        paint: Paint,
        text: CharSequence,
        start: Int,
        end: Int,
        fm: Paint.FontMetricsInt?,
    ): Int {
        if (measuredWidth <= 0) return 0
        if (fm != null) {
            fm.ascent = -contentHeight
            fm.descent = 0
            fm.top = fm.ascent
            fm.bottom = 0
        }
        return measuredWidth
    }

    override fun draw(
        canvas: Canvas,
        text: CharSequence,
        start: Int,
        end: Int,
        x: Float,
        top: Int,
        y: Int,
        bottom: Int,
        p: Paint,
    ) {
        val available = SpanUtils.width(canvas, text)
        val target = if (available > 0) available else canvas.width
        if (target > 0 && target != measuredWidth) {
            // First real measurement, or the view changed width.
            preparePaints(p as? TextPaint)
            measure(target)
            invalidator?.invoke()
        }
        if (slots.isEmpty()) return

        val border = style.borderWidth
        val cols = colWidths.size
        val rows = rowHeights.size
        val colOffset = IntArray(cols + 1)
        for (k in 0 until cols) colOffset[k + 1] = colOffset[k] + border + colWidths[k]
        val rowOffset = IntArray(rows + 1)
        for (r in 0 until rows) rowOffset[r + 1] = rowOffset[r] + border + rowHeights[r]

        // Row backgrounds: the header row keeps its own tint, the body stripes.
        for (r in 0 until rows) {
            val header = table.rows[r].cells.any { it.isHeader }
            fillPaint.color = when {
                header -> style.headerBackground
                r % 2 == 1 -> style.oddRowBackground
                else -> 0
            }
            if (fillPaint.color != 0) {
                canvas.drawRect(
                    x,
                    (top + rowOffset[r]).toFloat(),
                    x + contentWidth,
                    (top + rowOffset[r + 1]).toFloat(),
                    fillPaint,
                )
            }
        }

        fillPaint.color = style.borderColor
        for (k in 0..cols) {
            val left = x + colOffset[k]
            canvas.drawRect(left, top.toFloat(), left + border, (top + contentHeight).toFloat(), fillPaint)
        }
        for (r in 0..rows) {
            val edge = top + rowOffset[r]
            canvas.drawRect(x, edge.toFloat(), x + contentWidth, (edge + border).toFloat(), fillPaint)
        }

        val pad = style.cellPadding
        for (slot in slots) {
            canvas.save()
            canvas.translate(
                (x + colOffset[slot.col] + border + pad),
                (top + rowOffset[slot.row] + border + pad).toFloat(),
            )
            slot.layout.draw(canvas)
            canvas.restore()
        }
    }

    private fun preparePaints(source: TextPaint?) {
        if (source != null) bodyPaint.set(source)
        bodyPaint.color = style.textColor
        bodyPaint.textSize = style.textSize
        bodyPaint.isFakeBoldText = false
        headerPaint.set(bodyPaint)
        headerPaint.isFakeBoldText = true
    }

    /**
     * Type scale that keeps a column readable at [inner] pixels across [cols]
     * columns. A grid too wide for the screen otherwise ends up with cells one
     * character wide, which reads as broken rather than dense.
     *
     * 0.62 is the floor where glyphs stay recognisable; below that the columns
     * would collapse into slivers, so the floor wins and the table stays dense.
     */
    private fun readableScale(inner: Int, cols: Int): Float {
        // A column holds at least four Han characters at full size.
        val want = style.textSize * 4.5f * cols
        if (want <= inner) return 1f
        return (inner / want).coerceIn(0.62f, 1f)
    }

    /**
     * Width of the longest unbreakable run, so a column never splits a word.
     *
     * CJK has no spaces to break on but does break between characters, so Han
     * must not be measured as one word: 排队人数 would otherwise demand 4x the
     * width it needs, and a 17-column financial table could never fit.
     */
    private fun longestWord(paint: TextPaint, text: String): Float {
        var best = 0f
        val run = StringBuilder()

        fun flush() {
            if (run.isEmpty()) return
            val w = paint.measureText(run.toString())
            if (w > best) best = w
            run.setLength(0)
        }

        for (ch in text) {
            if (ch == ' ' || ch == '\n' || ch == '\t' || ch == '\u00a0' || isBreakableCjk(ch)) {
                flush()
                if (isBreakableCjk(ch)) {
                    val w = paint.measureText(ch.toString())
                    if (w > best) best = w
                }
            } else {
                run.append(ch)
            }
        }
        flush()
        return maxOf(best, paint.measureText("0"))
    }

    /** Han and full-width punctuation: line breaking is allowed between them. */
    private fun isBreakableCjk(ch: Char): Boolean = when (Character.UnicodeScript.of(ch.code)) {
        Character.UnicodeScript.HAN,
        Character.UnicodeScript.HIRAGANA,
        Character.UnicodeScript.KATAKANA,
        Character.UnicodeScript.HANGUL -> true
        else -> ch in '\u3000'..'\u303F' || ch in '\uFF00'..'\uFF60'
    }

    private fun measure(available: Int) {
        val cols = table.columnCount
        if (cols <= 0 || table.rows.isEmpty()) {
            // Nothing to lay out, but still claim the width: leaving
            // measuredWidth at 0 makes draw() re-measure and request a layout on
            // every frame, and that loop never converges.
            measuredWidth = available
            contentHeight = 0
            return
        }
        val border = style.borderWidth
        val inner = (available - border * (cols + 1)).coerceAtLeast(cols)

        // A 17-column finance grid on a phone leaves ~65 px per column, which
        // at 13sp fits a single character. Shrink the type (and padding) with it.
        val ratio = readableScale(inner, cols)
        bodyPaint.textSize = style.textSize * ratio
        headerPaint.textSize = style.textSize * ratio
        headerPaint.isFakeBoldText = true
        val pad = (style.cellPadding * ratio).toInt().coerceAtLeast(2)

        val widths = tableColumnWidths(table, inner, pad) { text, header ->
            val paint = if (header) headerPaint else bodyPaint
            paint.measureText(text) to longestWord(paint, text)
        }
        colWidths = widths

        val rowCount = table.rows.size
        val heights = IntArray(rowCount)
        val minRow = pad * 2 + ceil(bodyPaint.textSize * 1.4f).toInt()
        val placed = ArrayList<Slot>()
        for (r in 0 until rowCount) {
            var c = 0
            for (cell in table.rows[r].cells) {
                if (c >= cols) break
                val colSpan = cell.colspan.coerceIn(1, cols - c)
                val rowSpan = cell.rowspan.coerceIn(1, rowCount - r)
                val textWidth = (c until c + colSpan).sumOf { widths[it] } - pad * 2
                val paint = if (cell.isHeader) headerPaint else bodyPaint
                val layout = StaticLayout.Builder
                    .obtain(cell.text, 0, cell.text.length, paint, maxOf(textWidth, 1))
                    .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                    .setIncludePad(false)
                    .build()
                placed.add(Slot(r, c, rowSpan, colSpan, layout))
                if (rowSpan == 1) heights[r] = maxOf(heights[r], layout.height + pad * 2)
                c += colSpan
            }
            heights[r] = maxOf(heights[r], minRow)
        }

        // A rowspan cell has to fit in the rows it covers; grow them evenly.
        for (slot in placed) {
            if (slot.rowSpan <= 1) continue
            val needed = slot.layout.height + pad * 2
            val last = minOf(slot.row + slot.rowSpan, rowCount)
            var have = 0
            for (r in slot.row until last) have += heights[r]
            if (needed > have) {
                val extra = (needed - have + slot.rowSpan - 1) / slot.rowSpan
                for (r in slot.row until last) heights[r] += extra
            }
        }

        slots = placed
        rowHeights = heights
        contentWidth = widths.sum() + border * (cols + 1)
        contentHeight = heights.sum() + border * (rowCount + 1)
        measuredWidth = available
    }
}

/**
 * Column widths for a grid that has to fit in [inner] pixels.
 *
 * Each column has a minimum (what it needs before any word breaks -- a year
 * must not split "2020" into "202" + "0") and a natural width (no wrapping at
 * all). Sharing [inner] in proportion to the natural width alone starved narrow
 * columns, because a small column only got a small slice of a total the wide
 * columns dominated.
 *
 * [measure] returns the full text width and the longest unbreakable run.
 */
internal fun tableColumnWidths(
    table: OcrTable,
    inner: Int,
    pad: Int,
    measure: (text: String, header: Boolean) -> Pair<Float, Float>,
): IntArray {
    val cols = table.columnCount
    val minWidth = IntArray(cols) { pad * 2 }
    val natural = IntArray(cols) { pad * 2 }
    for (row in table.rows) {
        var c = 0
        for (cell in row.cells) {
            if (c >= cols) break
            val span = cell.colspan.coerceIn(1, cols - c)
            // A spanning cell gets its own pass once single columns are known.
            if (span == 1) {
                val (full, longest) = measure(cell.text, cell.isHeader)
                val want = ceil(full).toInt() + pad * 2
                val need = ceil(longest).toInt() + pad * 2
                if (want > natural[c]) natural[c] = want
                if (need > minWidth[c]) minWidth[c] = need
            }
            c += span
        }
    }
    for (j in 0 until cols) if (natural[j] < minWidth[j]) natural[j] = minWidth[j]

    val widths = IntArray(cols)
    val minTotal = minWidth.sum()
    if (minTotal >= inner) {
        // Too narrow even at the minimum: scale down and let the cells wrap.
        for (j in 0 until cols) {
            widths[j] = (minWidth[j] * inner / minTotal).coerceAtLeast(pad * 2 + 1)
        }
    } else {
        minWidth.copyInto(widths)
        val extra = IntArray(cols) { natural[it] - minWidth[it] }
        val extraTotal = extra.sum()
        val pool = inner - minTotal
        if (extraTotal <= 0) {
            for (j in 0 until cols) widths[j] += pool / cols
        } else {
            var used = 0
            for (j in 0 until cols) {
                val add = pool * extra[j] / extraTotal
                widths[j] += add
                used += add
            }
            // Rounding remainder, so the grid lands exactly on `inner`.
            var k = 0
            while (used < pool && k < cols * 8) {
                widths[k % cols] += 1
                used += 1
                k += 1
            }
        }
    }

    // A colspan cell still has to fit across the columns it covers.
    for (row in table.rows) {
        var c = 0
        for (cell in row.cells) {
            if (c >= cols) break
            val span = cell.colspan.coerceIn(1, cols - c)
            if (span > 1) {
                val need = ceil(measure(cell.text, cell.isHeader).second).toInt() + pad * 2
                var have = 0
                for (k in c until c + span) have += widths[k]
                if (have < need) {
                    val add = (need - have + span - 1) / span
                    for (k in c until c + span) widths[k] += add
                }
            }
            c += span
        }
    }

    // Widening for a colspan can overshoot; take it back from the columns with
    // the most surplus so the grid still fits the view.
    var overflow = widths.sum() - inner
    var guard = 0
    while (overflow > 0 && guard++ < cols * 8) {
        var j = -1
        for (k in 0 until cols) {
            if (widths[k] > minWidth[k] &&
                (j < 0 || widths[k] - minWidth[k] > widths[j] - minWidth[j])
            ) {
                j = k
            }
        }
        if (j < 0) break
        val trim = minOf(widths[j] - minWidth[j], overflow)
        widths[j] -= trim
        overflow -= trim
    }
    return widths
}
