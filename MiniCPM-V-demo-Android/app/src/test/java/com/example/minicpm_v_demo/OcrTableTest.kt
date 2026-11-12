package com.example.minicpm_v_demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Table parsing, masking and column widths -- everything that needs no view. */
class OcrTableTest {

    private val appendix =
        "<table><tr><td>Year</td><td>Recipient</td></tr>" +
            "<tr><td>1999</td><td>X Window System*</td></tr>" +
            "<tr><td colspan=\"2\">* Given to the Community at Large</td></tr></table>"

    @Test
    fun parsesRowsAndColumns() {
        val table = OcrHtmlTable.parse(appendix)
        assertNotNull(table)
        assertEquals(2, table!!.columnCount)
        assertEquals(3, table.rows.size)
        assertEquals("Year", table.rows[0].cells[0].text)
    }

    @Test
    fun keepsColspan() {
        val table = OcrHtmlTable.parse(appendix)!!
        val footer = table.rows[2].cells.single()
        assertEquals(2, footer.colspan)
        assertTrue(footer.text.startsWith("* Given"))
    }

    @Test
    fun keepsRowspanAndSkipsClaimedColumn() {
        val html = "<table><tr><td rowspan=\"2\">A</td><td>B</td></tr>" +
            "<tr><td>C</td></tr></table>"
        val table = OcrHtmlTable.parse(html)!!
        assertEquals(2, table.columnCount)
        assertEquals("A", table.rows[0].cells[0].text)
        assertEquals(2, table.rows[0].cells[0].rowspan)
        // "C" belongs in column 1, not under the rowspan cell.
        assertEquals("C", table.rows[1].cells.single().text)
    }

    @Test
    fun decodesEntitiesAndDropsTags() {
        val html = "<table><tr><td><b>a</b>&amp;b<br>c&nbsp;d</td></tr></table>"
        val table = OcrHtmlTable.parse(html)!!
        assertEquals("a&b c d", table.rows[0].cells.single().text)
    }

    @Test
    fun rejectsNonTable() {
        assertEquals(null, OcrHtmlTable.parse("no rows here"))
    }

    @Test
    fun firstRowIsTreatedAsHeader() {
        // The model emits <td> everywhere, so the header has to be inferred.
        val table = OcrHtmlTable.parse(
            "<table><tr><td>Year</td><td>Recipient</td></tr>" +
                "<tr><td>1999</td><td>X Window System</td></tr></table>"
        )!!
        assertTrue(table.rows[0].cells.all { it.isHeader })
        assertTrue(table.rows[1].cells.none { it.isHeader })
    }

    @Test
    fun singleFullWidthFirstRowIsNotHeader() {
        val table = OcrHtmlTable.parse(
            "<table><tr><td colspan=\"2\">* footnote</td></tr>" +
                "<tr><td>a</td><td>b</td></tr></table>"
        )!!
        assertTrue(table.rows[0].cells.none { it.isHeader })
    }

    @Test
    fun maskLeavesMarkdownUntouchedWhenNoTable() {
        val masked = OcrTableMarkdown.mask("plain text")
        assertEquals("plain text", masked.markdown)
        assertTrue(masked.tables.isEmpty())
    }

    @Test
    fun maskReplacesTableWithPlaceholder() {
        val masked = OcrTableMarkdown.mask("before\n\n$appendix\n\nafter")
        assertEquals(1, masked.tables.size)
        assertTrue(masked.markdown.contains("before"))
        assertTrue(masked.markdown.contains("after"))
        assertTrue(!masked.markdown.contains("<table"))
        assertTrue(!masked.markdown.contains("<td"))
        // The token has to survive commonmark: C0 controls get stripped, which
        // is how a \u0001 placeholder once rendered as "TB0".
        assertTrue(masked.markdown.contains("\u27E6TB0\u27E7"))
    }

    @Test
    fun maskHandlesUnclosedTable() {
        // postprocess only appends the missing </table> for html output, so a
        // truncated table still reaches the renderer.
        val masked = OcrTableMarkdown.mask("<table><tr><td>a</td><td>b</td></tr>")
        assertEquals(1, masked.tables.size)
        assertTrue(!masked.markdown.contains("<td"))
    }

    @Test
    fun maskKeepsCellTextWhenMarkupIsUnusable() {
        val masked = OcrTableMarkdown.mask("<table><tr><td>keep me</td></tr>".replace("<tr>", "<x>"))
        assertTrue(masked.tables.isEmpty())
        assertTrue(masked.markdown.contains("keep me"))
    }

    @Test
    fun dropsTrailingEmptyRows() {
        // The model often ends the table with a row of empty <td>s.
        val table = OcrHtmlTable.parse(
            "<table><tr><td>Year</td><td>Value</td></tr>" +
                "<tr><td>2024</td><td>76</td></tr>" +
                "<tr><td></td><td></td></tr></table>"
        )!!
        assertEquals(2, table.rows.size)
    }

    // MARK: column widths

    /** Fake metrics: every glyph 10px wide, words measured as length * 10. */
    private val metrics: (String, Boolean) -> Pair<Float, Float> = { text, _ ->
        val full = text.length * 10f
        val longest = text.split(' ').maxOfOrNull { it.length }?.times(10f) ?: 10f
        full to longest
    }

    private fun yearTable() = OcrHtmlTable.parse(
        "<table><tr><td>Year</td><td>Low EGD</td><td>Middle EGD</td><td>High EGD</td><td>Very high EGD</td></tr>" +
            "<tr><td>2014</td><td>32 (16.6%)</td><td>64 (38.3%)</td><td>74 (38.3%)</td><td>25 (13.0%)</td></tr>" +
            "<tr><td>2024</td><td>11 (5.7%)</td><td>44 (22.8%)</td><td>62 (32.1%)</td><td>76 (39.4%)</td></tr>" +
            "</table>"
    )!!

    @Test
    fun widthsSumToAvailableSpace() {
        val table = yearTable()
        val inner = 900
        val widths = tableColumnWidths(table, inner, 6, metrics)
        assertEquals(inner, widths.sum())
    }

    @Test
    fun narrowYearColumnStillFitsFourDigits() {
        // "2020" must not wrap into "202" + "0", which is what proportional
        // distribution against the wide text columns produced.
        val table = yearTable()
        val widths = tableColumnWidths(table, 900, 6, metrics)
        // 4 chars * 10px + 2 * padding
        assertTrue("year column too narrow: ${widths[0]}", widths[0] >= 40 + 12)
    }

    @Test
    fun wideColumnsGetTheSurplus() {
        val table = yearTable()
        val widths = tableColumnWidths(table, 900, 6, metrics)
        assertTrue(widths[0] < widths[4])
    }

    @Test
    fun doesNotExceedSpaceWhenContentCannotFit() {
        val table = yearTable()
        // Far narrower than the minimum: the grid still has to stay on screen.
        val widths = tableColumnWidths(table, 300, 6, metrics)
        assertTrue(widths.sum() <= 300)
    }

    @Test
    fun colspanColumnIsWidenedToFitItsCell() {
        val table = OcrHtmlTable.parse(
            "<table><tr><td>a</td><td>b</td></tr>" +
                "<tr><td colspan=\"2\">a very long footer line</td></tr></table>"
        )!!
        val widths = tableColumnWidths(table, 400, 6, metrics)
        assertEquals(400, widths.sum())
        assertTrue(widths.sum() >= "footer".length * 10 + 12)
    }
}
