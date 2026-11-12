package com.example.minicpm_v_demo

import android.text.Spannable
import android.text.Spanned
import android.text.TextPaint
import io.noties.markwon.Markwon

/**
 * Renders OCR tables, which Markwon cannot do on its own.
 *
 * A `<table>` block parses to a commonmark `HtmlBlock`, Markwon core has no
 * visitor for that node, and it has no children to fall back to, so the table
 * disappears entirely. The tables are instead lifted out of the markdown,
 * replaced by a placeholder token, and covered with an [OcrTableSpan] after
 * Markwon lays the text out.
 *
 * Masking runs *before* [OcrLatexMarkdown.prepare], otherwise a lone `$` in a
 * cell could pair with one elsewhere on the page and corrupt both.
 *
 * Display-only, like [OcrLatexMarkdown]: the markdown handed to the user (and
 * any exporter) keeps its original `<table>` markup.
 */
object OcrTableMarkdown {

    // Commonmark strips C0 control characters out of text nodes, which turned a
    // \u0001-prefixed placeholder into a literal "TB0" on screen. Mathematical
    // white brackets are ordinary symbols, so they survive parsing.
    private const val OPEN = '\u27E6'
    private const val CLOSE = '\u27E7'
    private const val PREFIX = "TB"
    private val placeholderRE = Regex("""\u27E6TB(\d+)\u27E7""")

    private val tableRE = Regex("""<table\b[\s\S]*?</table>""", RegexOption.IGNORE_CASE)
    private val openTableRE = Regex("""<table\b[\s\S]*""", RegexOption.IGNORE_CASE)
    private val anyTag = Regex("""<[^>]*>""")

    /** A markdown string whose tables were swapped for placeholders. */
    class Masked(val markdown: String, val tables: List<OcrTable>)

    fun mask(markdown: String): Masked {
        if (!markdown.contains("<table", ignoreCase = true)) return Masked(markdown, emptyList())
        val tables = ArrayList<OcrTable>()
        var out = tableRE.replace(markdown) { match ->
            val table = OcrHtmlTable.parse(match.value) ?: return@replace fallback(match.value)
            tables.add(table)
            // Own paragraph, so the span becomes its own line.
            "\n\n$OPEN$PREFIX${tables.size - 1}$CLOSE\n\n"
        }
        // A truncated table has no closing tag, so it would stay an HtmlBlock
        // and be dropped, losing the text entirely.
        if (out.contains("<table", ignoreCase = true)) {
            out = openTableRE.replace(out) { match ->
                val table = OcrHtmlTable.parse(match.value + "</table>")
                if (table != null) {
                    tables.add(table)
                    "\n\n$OPEN$PREFIX${tables.size - 1}$CLOSE\n\n"
                } else {
                    fallback(match.value)
                }
            }
        }
        return Masked(out, tables)
    }

    /** Keeps the cell text visible when the markup cannot be read as a table. */
    private fun fallback(html: String): String =
        html.replace(Regex("""</t[dh]>|</tr>""", RegexOption.IGNORE_CASE), " ")
            .replace(anyTag, " ")
            .replace(Regex("""[ \t]+"""), " ")
            .trim()

    /**
     * Attaches one [OcrTableSpan] per placeholder. `onInvalidate` fires when a
     * span needs a re-measure after finding its width; `null` leaves the first
     * measured width in place.
     */
    fun attach(
        spanned: Spanned,
        tables: List<OcrTable>,
        style: OcrTableStyle,
        basePaint: TextPaint?,
        preferredWidth: Int,
        onInvalidate: (() -> Unit)?,
    ): Spanned {
        if (tables.isEmpty()) return spanned
        val text = if (spanned is Spannable) spanned else Spannable.Factory.getInstance().newSpannable(spanned)
        val raw = text.toString()
        for (match in placeholderRE.findAll(raw)) {
            val index = match.groupValues[1].toIntOrNull() ?: continue
            val table = tables.getOrNull(index) ?: continue
            val span = OcrTableSpan(table, style, basePaint, preferredWidth)
            span.invalidator = onInvalidate
            text.setSpan(span, match.range.first, match.range.last + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return text
    }

    /** Convenience wrapper: mask, render, attach. */
    fun render(
        markwon: Markwon,
        markdown: String,
        style: OcrTableStyle,
        basePaint: TextPaint?,
        preferredWidth: Int,
        onInvalidate: (() -> Unit)?,
    ): Spanned {
        val masked = mask(markdown)
        // LaTeX runs on the masked text: a lone `$` in a cell would otherwise
        // pair with one elsewhere on the page.
        val spanned = markwon.toMarkdown(OcrLatexMarkdown.prepare(masked.markdown))
        return attach(spanned, masked.tables, style, basePaint, preferredWidth, onInvalidate)
    }
}
