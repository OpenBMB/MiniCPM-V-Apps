//
//  OcrMarkdownRenderer.swift
//  MiniCPM-V-demo
//
//  GitHub-flavored Markdown -> NSAttributedString renderer for the OCR
//  result view only. Chat uses the stock MarkdownRenderer so OCR spacing
//  / tables / line heights cannot leak into V-4.6 (or other) bubbles.
//

import UIKit
import iosMath

enum OcrMarkdownRenderer {

    // MARK: - Public API

    /// Render Markdown with the OCR GitHub-flavored spacing, line heights,
    /// and table layout. `fontSizeOffset` is added to every non-heading
    /// element's font size (OCR preview uses 2).
    static func render(
        _ markdown: String,
        baseAttributes: [NSAttributedString.Key: Any],
        fontSizeOffset: CGFloat = 2,
        maxFormulaWidth: CGFloat = 0
    ) -> NSAttributedString {
        let useGitHubStyle = true

        let baseFont = baseAttributes[.font] as? UIFont
            ?? UIFont.systemFont(ofSize: 16)
        let baseColor = baseAttributes[.foregroundColor] as? UIColor ?? .label

        // Adjusted size for everything except headings
        let adjustedSize = baseFont.pointSize + fontSizeOffset
        let adjustedFont = baseFont.withSize(adjustedSize)

        // Default paragraph spacing ≈ 2/3 of line height (compact chat-mode gaps).
        // List items and headings override this to 0 for tight inter-item / post-title spacing.
        let defaultLineH = adjustedSize * 1.3
        let defaultParaSpacing = round(defaultLineH * 2.0 / 3.0)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = defaultParaSpacing
        var adjustedAttributes = mergedAttributes(base: baseAttributes, overrides: [
            .font: adjustedFont,
            .paragraphStyle: defaultPara
        ])

        // ---- GitHub-style helpers (only used when useGitHubStyle == true) ----
        let ghBodyLineH: CGFloat = round(adjustedSize * 1.625)
        let ghParaSpacing:    CGFloat = useGitHubStyle ? 12 : 0
        let ghCodeBg   = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 1.0)
            : UIColor(red: 0.965, green: 0.973, blue: 0.980, alpha: 1.0) } // #F6F8FA
        let ghQuoteColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.62, alpha: 1.0)
            : UIColor(red: 0.396, green: 0.427, blue: 0.463, alpha: 1.0) } // #656D76
        let ghQuoteBorderColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.38, alpha: 1.0)
            : UIColor(red: 0.816, green: 0.843, blue: 0.871, alpha: 1.0) } // #D0D7DE

        func ghBodyPara() -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = ghBodyLineH
            p.maximumLineHeight = ghBodyLineH
            p.paragraphSpacing   = ghParaSpacing
            return p
        }

        func mathPara(center: Bool) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.alignment = center ? .center : .natural
            p.paragraphSpacingBefore = center ? 6 : 0
            p.paragraphSpacing = center ? 8 : ghParaSpacing
            p.lineBreakMode = .byWordWrapping
            return p
        }

        func ghHeadingPara(level: Int) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            let sizes: [(CGFloat, CGFloat)] = [(28,24), (22,20), (18,16), (16,12), (15,12), (14,12)]
            let (fs, before) = level <= sizes.count ? sizes[level-1] : (14, 12)
            let lh = round(fs * 1.25)
            p.minimumLineHeight = lh
            p.maximumLineHeight = lh
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = {
                let after: [CGFloat] = [16, 12, 8, 4, 4, 4]
                return level <= after.count ? after[level-1] : 4
            }()
            return p
        }

        let result = NSMutableAttributedString()
        let blocks = parseBlocks(markdown)

        for (idx, block) in blocks.enumerated() {
            switch block.type {
            case .heading:
                let fontSize: CGFloat
                if useGitHubStyle {
                    let ghHeadSizes: [CGFloat] = [28, 22, 18, 16, 15, 14]
                    fontSize = (block.level >= 1 && block.level <= ghHeadSizes.count)
                        ? ghHeadSizes[block.level - 1] : 14
                } else {
                    fontSize = headingFontSize(level: block.level, base: baseFont.pointSize)
                }
                let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                var attrs = mergedAttributes(base: baseAttributes, overrides: [.font: font])
                if useGitHubStyle {
                    attrs[.paragraphStyle] = ghHeadingPara(level: block.level)
                }
                let rendered = renderInlineSpans(block.spans, baseAttributes: attrs, baseFont: font, baseColor: baseColor,
                                                  useGitHubStyle: useGitHubStyle)
                result.append(rendered)

            case .codeBlock:
                let codeSize = useGitHubStyle ? adjustedSize * 0.85 : adjustedSize - 2
                let codeFont = UIFont(name: "Menlo", size: codeSize)
                    ?? UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
                let codePara = NSMutableParagraphStyle()
                if useGitHubStyle {
                    codePara.minimumLineHeight = round(codeSize * 1.45)
                    codePara.maximumLineHeight = codePara.minimumLineHeight
                    codePara.lineBreakMode = .byWordWrapping
                } else {
                    codePara.lineSpacing = 2
                    codePara.lineBreakMode = .byWordWrapping
                }
                let codeAttrs: [NSAttributedString.Key: Any] = useGitHubStyle ? [
                    .font: codeFont,
                    .foregroundColor: baseColor,
                    .backgroundColor: ghCodeBg,
                    .paragraphStyle: codePara
                ] : [
                    .font: codeFont,
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor { $0.userInterfaceStyle == .dark
                        ? UIColor(white: 0.22, alpha: 1.0)
                        : UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0) },
                    .paragraphStyle: codePara
                ]
                result.append(NSAttributedString(string: block.raw, attributes: codeAttrs))

            case .listItem:
                let bullet: String
                if block.level == 0 {
                    bullet = "  •  "
                } else {
                    bullet = "  \(block.level).  "
                }
                var bulletAttrs = mergedAttributes(base: adjustedAttributes, overrides: [
                    .foregroundColor: baseColor
                ])
                // Override paragraphSpacing to 0 for compact list items.
                let listPara = (bulletAttrs[.paragraphStyle] as? NSMutableParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                listPara.paragraphSpacing = 0
                bulletAttrs[.paragraphStyle] = listPara
                if useGitHubStyle {
                    listPara.minimumLineHeight = ghBodyLineH
                    listPara.headIndent = 20
                    listPara.firstLineHeadIndent = 0
                    bulletAttrs[.paragraphStyle] = listPara
                }
                result.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
                // Content of the list item also gets paragraphSpacing = 0
                var itemContentAttrs = adjustedAttributes
                let itemPara = (itemContentAttrs[.paragraphStyle] as? NSMutableParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                itemPara.paragraphSpacing = 0
                itemContentAttrs[.paragraphStyle] = itemPara
                let rendered = renderInlineSpans(block.spans, baseAttributes: itemContentAttrs, baseFont: adjustedFont, baseColor: baseColor,
                                                  useGitHubStyle: useGitHubStyle)
                result.append(rendered)

            case .blockquote:
                if useGitHubStyle {
                    let quotePara = NSMutableParagraphStyle()
                    quotePara.minimumLineHeight = ghBodyLineH
                    quotePara.headIndent = 16
                    quotePara.firstLineHeadIndent = 16
                    quotePara.paragraphSpacing = 12
                    let quoteAttrs: [NSAttributedString.Key: Any] = [
                        .font: adjustedFont,
                        .foregroundColor: ghQuoteColor,
                        .paragraphStyle: quotePara
                    ]
                    let barAttrs: [NSAttributedString.Key: Any] = [
                        .font: adjustedFont,
                        .foregroundColor: ghQuoteBorderColor,
                        .paragraphStyle: quotePara
                    ]
                    let bar = NSAttributedString(string: "\u{2503}\u{00A0}", attributes: barAttrs)
                    result.append(bar)
                    let rendered = renderInlineSpans(block.spans, baseAttributes: quoteAttrs, baseFont: adjustedFont, baseColor: ghQuoteColor,
                                                      useGitHubStyle: true)
                    result.append(rendered)
                } else {
                    let quoteColor = UIColor.gray
                    let quoteFont = UIFont.italicSystemFont(ofSize: adjustedSize)
                    let quoteAttrs = mergedAttributes(base: adjustedAttributes, overrides: [
                        .foregroundColor: quoteColor,
                        .font: quoteFont
                    ])
                    let rendered = renderInlineSpans(block.spans, baseAttributes: quoteAttrs, baseFont: quoteFont, baseColor: quoteColor)
                    let bar = NSAttributedString(string: "  ▎ ", attributes: quoteAttrs)
                    result.append(bar)
                    result.append(rendered)
                }

            case .horizontalRule:
                let rulePara = NSMutableParagraphStyle()
                rulePara.lineBreakMode = .byClipping
                rulePara.maximumLineHeight = 22
                rulePara.minimumLineHeight = 22
                let ruleAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.separator,
                    .font: adjustedFont,
                    .paragraphStyle: rulePara
                ]
                let ruleStr = String(repeating: "─", count: 80)
                result.append(NSAttributedString(string: ruleStr, attributes: ruleAttrs))

            case .table:
                if let td = block.tableData {
                    result.append(renderTable(td, baseFont: adjustedFont, baseColor: baseColor, useGitHubStyle: useGitHubStyle))
                } else {
                    // Fallback: Markdown pipe table or unparseable HTML — render as monospace
                    let tableFont = UIFont(name: "Menlo", size: adjustedSize - 2)
                        ?? UIFont.monospacedSystemFont(ofSize: adjustedSize - 2, weight: .regular)
                    let tablePara = NSMutableParagraphStyle()
                    tablePara.lineSpacing = 0
                    tablePara.lineBreakMode = .byClipping
                    let tableColor = UIColor.darkGray
                    let tableAttrs: [NSAttributedString.Key: Any] = [
                        .font: tableFont,
                        .foregroundColor: tableColor,
                        .paragraphStyle: tablePara
                    ]
                    result.append(NSAttributedString(string: block.raw, attributes: tableAttrs))
                }

            case .displayMath:
                let para = mathPara(center: true)
                if let image = OcrMathImages.image(latex: block.raw, display: true, fontSize: adjustedSize, maxWidth: maxFormulaWidth) {
                    result.append(formulaAttachment(image, maxWidth: maxFormulaWidth, font: adjustedFont, paragraph: para, inline: false))
                } else {
                    let attrs = mergedAttributes(base: adjustedAttributes, overrides: [
                        .font: UIFont.monospacedSystemFont(ofSize: adjustedSize, weight: .regular),
                        .paragraphStyle: para
                    ])
                    result.append(NSAttributedString(string: block.raw, attributes: attrs))
                }

            case .paragraph:
                let hasMath = block.spans.contains { $0.type == .math }
                var paraAttr = adjustedAttributes
                if useGitHubStyle {
                    paraAttr[.paragraphStyle] = hasMath ? mathPara(center: false) : ghBodyPara()
                }
                let rendered = renderInlineSpans(block.spans, baseAttributes: paraAttr, baseFont: adjustedFont, baseColor: baseColor,
                                                  useGitHubStyle: useGitHubStyle, maxFormulaWidth: maxFormulaWidth)
                result.append(rendered)
            }

            if idx < blocks.count - 1 {
                let hasMath = block.type == .displayMath
                    || (block.type == .paragraph && block.spans.contains { $0.type == .math })
                var sepAttrs = adjustedAttributes
                if hasMath {
                    sepAttrs[.paragraphStyle] = mathPara(center: block.type == .displayMath)
                }
                result.append(NSAttributedString(string: "\n", attributes: sepAttrs))
            }
        }

        return result
    }

    // MARK: - Block parsing

    private enum BlockType {
        case paragraph
        case heading
        case listItem
        case codeBlock
        case blockquote
        case horizontalRule
        case table
        case displayMath
    }

    private struct Block {
        let type: BlockType
        let level: Int       // heading 1-6; ordered list index; 0 for unordered/others
        let language: String // code block language hint
        let spans: [InlineSpan]
        let raw: String      // code block raw content
        let tableData: TableData? // parsed HTML table structure (nil for non-table blocks)
    }

    /// Parsed HTML table structure used for NSTextTab-aligned rendering.
    struct TableData {
        struct Cell {
            let text: String
            let isHeader: Bool
            let colspan: Int
        }
        let rows: [[Cell]]
        let columnCount: Int
    }

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks = [Block]()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines = [String]()
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                blocks.append(Block(
                    type: .codeBlock, level: 0, language: lang,
                    spans: [], raw: codeLines.joined(separator: "\n"), tableData: nil))
                continue
            }

            // Heading
            if let match = line.range(of: #"^(#{1,6})\s+(.*)$"#, options: .regularExpression) {
                let fullMatch = String(line[match])
                let hashEnd = fullMatch.firstIndex(of: " ")!
                let level = fullMatch.distance(from: fullMatch.startIndex, to: hashEnd)
                let content = String(fullMatch[fullMatch.index(after: hashEnd)...])
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(Block(
                    type: .heading, level: level, language: "",
                    spans: parseInline(content), raw: content, tableData: nil))
                i += 1
                continue
            }

            // Horizontal rule (---, ***, ___)
            if isHorizontalRule(line) {
                blocks.append(Block(
                    type: .horizontalRule, level: 0, language: "",
                    spans: [], raw: "", tableData: nil))
                i += 1
                continue
            }

            // Blockquote
            if line.hasPrefix("> ") || line == ">" {
                let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                blocks.append(Block(
                    type: .blockquote, level: 0, language: "",
                    spans: parseInline(content), raw: content, tableData: nil))
                i += 1
                continue
            }

            // Table: lines starting with | (collect consecutive table rows)
            if line.hasPrefix("|") && line.hasSuffix("|") {
                var tableLines = [line]
                i += 1
                while i < lines.count {
                    let tl = lines[i]
                    if tl.hasPrefix("|") {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }
                let tableRaw = tableLines.joined(separator: "\n")
                blocks.append(Block(
                    type: .table, level: 0, language: "",
                    spans: [], raw: tableRaw, tableData: nil))
                continue
            }

            // Unordered list item (- * + and en-dash – em-dash —)
            if let _ = line.range(of: #"^\s*[-*+–—]\s+(.*)$"#, options: .regularExpression) {
                let content = extractListContent(line, pattern: #"^\s*[-*+–—]\s+"#)
                blocks.append(Block(
                    type: .listItem, level: 0, language: "",
                    spans: parseInline(content), raw: content, tableData: nil))
                i += 1
                continue
            }

            // Ordered list item
            if let _ = line.range(of: #"^\s*(\d+)\.\s+(.*)$"#, options: .regularExpression) {
                let (num, content) = extractOrderedListContent(line)
                blocks.append(Block(
                    type: .listItem, level: num, language: "",
                    spans: parseInline(content), raw: content, tableData: nil))
                i += 1
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph: gather contiguous non-special lines
            var paraLines = [line]
            i += 1
            while i < lines.count {
                let peek = lines[i]
                if peek.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if peek.hasPrefix("```") { break }
                if peek.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { break }
                if peek.range(of: #"^\s*[-*+–—]\s+"#, options: .regularExpression) != nil { break }
                if peek.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) != nil { break }
                if peek.hasPrefix("> ") || peek == ">" { break }
                if peek.hasPrefix("|") && peek.hasSuffix("|") { break }
                if isHorizontalRule(peek) { break }
                paraLines.append(peek)
                i += 1
            }
            let paragraph = paraLines.joined(separator: "\n")

            if appendOTSL(paragraph, to: &blocks) { continue }

            // Detect inline HTML <table> within paragraph and split into
            // text / table / text blocks so the table renders as bordered text.
            if let tableRange = paragraph.range(of: "<table[\\s>]", options: .regularExpression) {
                let tableStart = tableRange.lowerBound
                let beforeText = String(paragraph[..<tableStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let afterStart = paragraph[tableStart...]
                if let endTagRange = afterStart.range(of: "</table>", options: .caseInsensitive) {
                    let tableHTML = String(afterStart[..<endTagRange.upperBound])
                    let afterText = String(afterStart[endTagRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

                    if !beforeText.isEmpty {
                        appendProse(beforeText, to: &blocks)
                    }
                    if let parsedTable = parseHTMLTable(tableHTML) {
                        blocks.append(Block(
                            type: .table, level: 0, language: "",
                            spans: [], raw: "", tableData: parsedTable))
                    }
                    if !afterText.isEmpty {
                        appendProse(afterText, to: &blocks)
                    }
                    continue
                }
            }

            appendProse(paragraph, to: &blocks)
        }

        return blocks
    }

    private static func appendOTSL(_ paragraph: String, to blocks: inout [Block]) -> Bool {
        guard paragraph.range(of: "<otsl>", options: .caseInsensitive) != nil else { return false }
        var rest = paragraph[...]
        while let open = rest.range(of: "<otsl>", options: .caseInsensitive) {
            let before = String(rest[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { appendProse(before, to: &blocks) }
            let after = rest[open.lowerBound...]
            guard let close = after.range(of: "</otsl>", options: .caseInsensitive) else {
                appendProse(String(after), to: &blocks)
                return true
            }
            let otsl = String(after[..<close.upperBound])
            let html = OcrOtsl.convert(otsl)
            if !html.isEmpty, let parsed = parseHTMLTable(html) {
                blocks.append(Block(
                    type: .table, level: 0, language: "",
                    spans: [], raw: "", tableData: parsed))
            } else {
                appendProse(otsl, to: &blocks)
            }
            rest = after[close.upperBound...]
        }
        let tail = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { appendProse(tail, to: &blocks) }
        return true
    }

    private static func appendProse(_ text: String, to blocks: inout [Block]) {
        var rest = text[...]
        while let open = rest.range(of: "$$") {
            appendPlain(String(rest[..<open.lowerBound]), to: &blocks)
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "$$") else {
                appendPlain(String(rest[open.lowerBound...]), to: &blocks)
                return
            }
            let latex = String(after[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !latex.isEmpty {
                blocks.append(Block(
                    type: .displayMath, level: 0, language: "",
                    spans: [], raw: latex, tableData: nil))
            }
            rest = after[close.upperBound...]
        }
        appendPlain(String(rest), to: &blocks)
    }

    private static func appendPlain(_ text: String, to blocks: inout [Block]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blocks.append(Block(
            type: .paragraph, level: 0, language: "",
            spans: parseInline(trimmed), raw: trimmed, tableData: nil))
    }

    private static func formulaAttachment(
        _ image: UIImage,
        maxWidth: CGFloat,
        font: UIFont,
        paragraph: NSParagraphStyle,
        inline: Bool
    ) -> NSAttributedString {
        var width = image.size.width
        var height = image.size.height
        if maxWidth > 0, width > maxWidth, width > 0 {
            let scale = maxWidth / width
            width = maxWidth
            height *= scale
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let y = inline ? (font.capHeight - height) / 2 : 0
        attachment.bounds = CGRect(x: 0, y: y, width: width, height: height)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func extractListContent(_ line: String, pattern: String) -> String {
        guard let range = line.range(of: pattern, options: .regularExpression) else {
            return line
        }
        return String(line[range.upperBound...])
    }

    private static func extractOrderedListContent(_ line: String) -> (Int, String) {
        guard let dotRange = line.range(of: #"^\s*(\d+)\.\s+"#, options: .regularExpression) else {
            return (1, line)
        }
        let prefix = String(line[line.startIndex..<dotRange.upperBound])
        let digits = prefix.filter { $0.isNumber }
        let num = Int(digits) ?? 1
        let content = String(line[dotRange.upperBound...])
        return (num, content)
    }

    // MARK: - Inline parsing

    private enum InlineType {
        case text
        case bold
        case italic
        case boldItalic
        case code
        case strikethrough
        case link
        case math
    }

    private struct InlineSpan {
        let type: InlineType
        let text: String
        let url: String // only for .link
    }

    private static func parseInline(_ text: String) -> [InlineSpan] {
        var spans = [InlineSpan]()
        var buf = ""
        var i = text.startIndex

        func flushBuf() {
            if !buf.isEmpty {
                spans.append(InlineSpan(type: .text, text: buf, url: ""))
                buf = ""
            }
        }

        func remaining(_ from: String.Index) -> Int {
            text.distance(from: from, to: text.endIndex)
        }

        while i < text.endIndex {
            let ch = text[i]

            if ch == "$" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] != "$",
                   let close = text[next...].firstIndex(of: "$") {
                    let inner = String(text[next..<close]).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty, !inner.contains("\n") {
                        flushBuf()
                        spans.append(InlineSpan(type: .math, text: inner, url: ""))
                        i = text.index(after: close)
                        continue
                    }
                }
            }

            // ***bold italic*** (three asterisks)
            if ch == "*", remaining(i) >= 6 {
                let i1 = text.index(after: i)
                let i2 = text.index(after: i1)
                if text[i1] == "*" && text[i2] == "*" {
                    let searchStart = text.index(i, offsetBy: 3)
                    if let closeRange = text.range(of: "***", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .boldItalic, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // **bold**
            if ch == "*", remaining(i) >= 4 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "*" {
                    let searchStart = text.index(i, offsetBy: 2)
                    if let closeRange = text.range(of: "**", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .bold, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // ~~strikethrough~~
            if ch == "~", remaining(i) >= 4 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "~" {
                    let searchStart = text.index(i, offsetBy: 2)
                    if let closeRange = text.range(of: "~~", range: searchStart..<text.endIndex) {
                        let inner = String(text[searchStart..<closeRange.lowerBound])
                        if !inner.isEmpty && !inner.contains("\n") {
                            flushBuf()
                            spans.append(InlineSpan(type: .strikethrough, text: inner, url: ""))
                            i = closeRange.upperBound
                            continue
                        }
                    }
                }
            }

            // *italic* or _italic_ (single marker, NOT followed by same char)
            if (ch == "*" || ch == "_"), remaining(i) >= 3 {
                let nextIdx = text.index(after: i)
                let next = text[nextIdx]
                if next != ch && next != " " && next != "\n" {
                    if let closeIdx = text[nextIdx...].firstIndex(of: ch) {
                        // Ensure closing marker is not part of a `**`
                        let afterClose = text.index(after: closeIdx)
                        let closingIsDouble = afterClose < text.endIndex && text[afterClose] == ch
                        if !closingIsDouble {
                            let inner = String(text[nextIdx..<closeIdx])
                            if !inner.isEmpty && !inner.contains("\n") {
                                flushBuf()
                                spans.append(InlineSpan(type: .italic, text: inner, url: ""))
                                i = afterClose
                                continue
                            }
                        }
                    }
                }
            }

            // `inline code`
            if ch == "`" {
                let nextIdx = text.index(after: i)
                if nextIdx < text.endIndex,
                   let closeIdx = text[nextIdx...].firstIndex(of: "`") {
                    let inner = String(text[nextIdx..<closeIdx])
                    if !inner.isEmpty {
                        flushBuf()
                        spans.append(InlineSpan(type: .code, text: inner, url: ""))
                        i = text.index(after: closeIdx)
                        continue
                    }
                }
            }

            // ![text](url) — image syntax (render as link with label)
            if ch == "!", remaining(i) >= 5 {
                let nextIdx = text.index(after: i)
                if text[nextIdx] == "[" {
                    if let result = parseLinkAt(text, from: nextIdx) {
                        flushBuf()
                        spans.append(InlineSpan(type: .link, text: "[\(result.text)]", url: result.url))
                        i = result.end
                        continue
                    }
                }
            }

            // [text](url)
            if ch == "[" {
                if let result = parseLinkAt(text, from: i) {
                    flushBuf()
                    spans.append(InlineSpan(type: .link, text: result.text, url: result.url))
                    i = result.end
                    continue
                }
            }

            buf.append(ch)
            i = text.index(after: i)
        }

        flushBuf()
        return spans
    }

    private struct LinkParseResult {
        let text: String
        let url: String
        let end: String.Index
    }

    private static func parseLinkAt(_ text: String, from start: String.Index) -> LinkParseResult? {
        guard text[start] == "[" else { return nil }
        let afterBracket = text.index(after: start)
        guard let closeBracket = text[afterBracket...].firstIndex(of: "]") else { return nil }
        let linkText = String(text[afterBracket..<closeBracket])

        let parenStart = text.index(after: closeBracket)
        guard parenStart < text.endIndex, text[parenStart] == "(" else { return nil }
        let afterParen = text.index(after: parenStart)
        guard let closeParen = text[afterParen...].firstIndex(of: ")") else { return nil }
        let url = String(text[afterParen..<closeParen])

        return LinkParseResult(text: linkText, url: url, end: text.index(after: closeParen))
    }

    // MARK: - Inline span -> NSAttributedString

    private static func renderInlineSpans(
        _ spans: [InlineSpan],
        baseAttributes: [NSAttributedString.Key: Any],
        baseFont: UIFont,
        baseColor: UIColor,
        useGitHubStyle: Bool = false,
        maxFormulaWidth: CGFloat = 0
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for span in spans {
            switch span.type {
            case .text:
                result.append(NSAttributedString(string: span.text, attributes: baseAttributes))

            case .math:
                let para = baseAttributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle()
                if let image = OcrMathImages.image(latex: span.text, display: false, fontSize: baseFont.pointSize, maxWidth: maxFormulaWidth) {
                    result.append(formulaAttachment(image, maxWidth: maxFormulaWidth, font: baseFont, paragraph: para, inline: true))
                } else {
                    result.append(NSAttributedString(string: span.text, attributes: baseAttributes))
                }

            case .bold:
                let boldFont = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: boldFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .italic:
                let italicFont = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: italicFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .boldItalic:
                let descriptor = UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                    .fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic])
                let biFont = descriptor.map { UIFont(descriptor: $0, size: baseFont.pointSize) }
                    ?? UIFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                let attrs = mergedAttributes(base: baseAttributes, overrides: [.font: biFont])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .code:
                let codeFontSize = baseFont.pointSize * (useGitHubStyle ? 0.88 : 1.0) - 1
                let codeFont = UIFont(name: "Menlo", size: codeFontSize)
                    ?? UIFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
                if useGitHubStyle {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: baseColor,
                        .backgroundColor: UIColor { $0.userInterfaceStyle == .dark
                            ? UIColor(white: 0.30, alpha: 0.55)
                            : UIColor(red: 0.910, green: 0.910, blue: 0.910, alpha: 0.35) }
                    ]
                    result.append(NSAttributedString(string: span.text, attributes: attrs))
                } else {
                    let attrs = mergedAttributes(base: baseAttributes, overrides: [
                        .font: codeFont,
                        .foregroundColor: UIColor { $0.userInterfaceStyle == .dark
                            ? UIColor(red: 0.95, green: 0.55, blue: 0.62, alpha: 1.0)
                            : UIColor(red: 0.78, green: 0.15, blue: 0.30, alpha: 1.0) },
                        .backgroundColor: UIColor { $0.userInterfaceStyle == .dark
                            ? UIColor(white: 0.24, alpha: 1.0)
                            : UIColor(red: 0.97, green: 0.93, blue: 0.94, alpha: 1.0) }
                    ])
                    result.append(NSAttributedString(string: span.text, attributes: attrs))
                }

            case .strikethrough:
                let attrs = mergedAttributes(base: baseAttributes, overrides: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ])
                result.append(NSAttributedString(string: span.text, attributes: attrs))

            case .link:
                let linkColor = useGitHubStyle
                    ? UIColor(red: 0.035, green: 0.412, blue: 0.855, alpha: 1.0) // #0969DA
                    : UIColor.systemBlue
                let attrs = mergedAttributes(base: baseAttributes, overrides: [
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ])
                result.append(NSAttributedString(string: span.text, attributes: attrs))
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Parse an HTML <table> string into structured TableData.
    /// Handles <tr>, <td>, <th>, colspan. Returns nil if parsing fails.
    private static func parseHTMLTable(_ html: String) -> TableData? {
        // Decode basic HTML entities
        func decodeEntities(_ s: String) -> String {
            s.replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&quot;", with: "\"")
             .replacingOccurrences(of: "&#39;", with: "'")
             .replacingOccurrences(of: "&#x27;", with: "'")
        }

        // Strip a single surrounding HTML tag
        func stripTag(_ tagged: String, tag: String) -> String {
            let open = "<\(tag)"
            guard let range = tagged.range(of: open, options: .caseInsensitive) else { return tagged }
            var s = String(tagged[range.upperBound...])
            if let gt = s.firstIndex(of: ">") { s = String(s[s.index(after: gt)...]) }
            let close = "</\(tag)>"
            if let r = s.range(of: close, options: .caseInsensitive) { s = String(s[..<r.lowerBound]) }
            return s
        }

        // Parse colspan from a cell tag
        func parseColspan(_ tagContent: String) -> Int {
            if let m = tagContent.range(of: #"colspan\s*=\s*"(\d+)""#, options: .regularExpression) {
                let numStr = String(tagContent[m]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                return Int(numStr) ?? 1
            } else if let m = tagContent.range(of: #"colspan\s*=\s*(\d+)"#, options: .regularExpression) {
                let numStr = String(tagContent[m]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                return Int(numStr) ?? 1
            }
            return 1
        }

        // Extract text and header flag from a cell
        func extractCell(_ raw: String) -> (text: String, isHeader: Bool, colspan: Int) {
            let isTH = raw.lowercased().hasPrefix("<th")
            let tagName = isTH ? "th" : "td"
            var rest = String(raw.dropFirst(isTH ? 3 : 3))
            var colspan = 1
            if let gt = rest.firstIndex(of: ">") {
                let tagContent = String(rest[..<gt])
                colspan = parseColspan(tagContent)
                rest = String(rest[rest.index(after: gt)...])
            }
            let inner = stripTag(raw, tag: tagName)
            return (decodeEntities(inner.trimmingCharacters(in: .whitespaces)), isTH, colspan)
        }

        // Remove outer <table> tags
        var htmlContent = stripTag(html, tag: "table")

        // Split by <tr>
        var rowStrings: [String] = []
        var searchRange = htmlContent.startIndex..<htmlContent.endIndex
        while let trOpen = htmlContent.range(of: "<tr", options: .caseInsensitive, range: searchRange) {
            let fromGT = htmlContent[trOpen.upperBound...]
            let afterTag: String.Index
            if let gt = fromGT.firstIndex(of: ">") {
                afterTag = htmlContent.index(after: gt)
            } else {
                afterTag = trOpen.upperBound
            }
            if let trClose = htmlContent.range(of: "</tr>", options: .caseInsensitive, range: afterTag..<htmlContent.endIndex) {
                rowStrings.append(String(htmlContent[afterTag..<trClose.lowerBound]))
                searchRange = trClose.upperBound..<htmlContent.endIndex
            } else {
                break
            }
        }

        guard !rowStrings.isEmpty else { return nil }

        var rows: [[TableData.Cell]] = []
        var maxCols = 0
        for rowStr in rowStrings {
            var cells: [TableData.Cell] = []
            var rest = rowStr
            while let tdOpen = rest.range(of: "<t[dh]", options: [.regularExpression, .caseInsensitive]) {
                let afterOpen = rest[tdOpen.lowerBound...]
                if let tdClose = afterOpen.range(of: "</t[dh]>", options: [.regularExpression, .caseInsensitive]) {
                    let cellRaw = String(afterOpen[..<tdClose.upperBound])
                    let (text, isHeader, colspan) = extractCell(cellRaw)
                    cells.append(TableData.Cell(text: text, isHeader: isHeader, colspan: colspan))
                    rest = String(afterOpen[tdClose.upperBound...])
                } else {
                    break
                }
            }
            if !cells.isEmpty {
                rows.append(cells)
                var colCount = 0
                for c in cells { colCount += c.colspan }
                if colCount > maxCols { maxCols = colCount }
            }
        }

        guard maxCols > 0 else { return nil }
        return TableData(rows: rows, columnCount: maxCols)
    }



    // MARK: - Table rendering (NSTextTab-aligned columns)

    /// Render a parsed HTML table as an NSAttributedString with tab-stop aligned
    /// columns, bold headers, alternating row backgrounds, and a separator line.
    private static func renderTable(
        _ table: TableData, baseFont: UIFont, baseColor: UIColor,
        useGitHubStyle: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let colCount = table.columnCount
        guard colCount > 0 else { return result }

        let tableFontSize = baseFont.pointSize - 1
        let tableFont = UIFont.systemFont(ofSize: tableFontSize)
        let headerFont = UIFont.systemFont(ofSize: tableFontSize, weight: .semibold)
        // Table fills and separators follow the appearance so dark mode does not
        // show white blocks under light text.
        let headerColor = useGitHubStyle
            ? baseColor
            : UIColor { $0.userInterfaceStyle == .dark ? .label : .white }
        let headerBgColor = useGitHubStyle
            ? UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.22, alpha: 1.0)
                : UIColor(red: 0.965, green: 0.973, blue: 0.980, alpha: 1.0) }  // #F6F8FA
            : UIColor(red: 0.25, green: 0.47, blue: 0.85, alpha: 1.0)
        let rowBgEven = useGitHubStyle
            ? UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 1.0)
                : UIColor(red: 0.980, green: 0.980, blue: 0.984, alpha: 1.0) }
            : UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 0.14, alpha: 1.0)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1.0) }
        let rowBgOdd = useGitHubStyle
            ? UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1.0) : .white }
            : UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.10, alpha: 1.0) : .white }
        let separatorColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.35, alpha: 1.0)
            : UIColor(white: 0.85, alpha: 1.0) }
        let cellHPadding: CGFloat = 8  // horizontal padding inside each "column"
        // 2.0x line height for comfortable table row reading
        let tableLineH: CGFloat = ceil(tableFontSize * 2.0)

        // Estimate column widths from maximum content width in each column
        let estimateAttributes: [NSAttributedString.Key: Any] = [.font: tableFont]
        var colWidths = Array(repeating: CGFloat(0), count: colCount)
        for row in table.rows {
            var ci = 0
            for cell in row {
                if ci < colCount {
                    let w = (cell.text as NSString).size(withAttributes: estimateAttributes).width
                    let cols = min(cell.colspan, colCount - ci)
                    let perCol = ceil(w / CGFloat(cols))
                    for o in 0..<cols {
                        colWidths[ci + o] = max(colWidths[ci + o], perCol)
                    }
                }
                ci += cell.colspan
            }
        }
        for j in 0..<colCount { colWidths[j] = max(colWidths[j], 40) }

        // Build tab stops at accumulated column positions.
        // The final stop at totalWidth allows a trailing tab to fill the
        // background color across the full row width.
        var tabStops: [NSTextTab] = []
        var x: CGFloat = 0
        for j in 0..<colCount {
            x += cellHPadding
            tabStops.append(NSTextTab(textAlignment: .left, location: x, options: [:]))
            x += colWidths[j] + cellHPadding
        }
        // Right-aligned stop at totalWidth — the trailing tab fills the row width.
        // Using right-alignment ensures the tab itself adds zero visible text width
        // while still stretching the background to the end of the row.
        tabStops.append(NSTextTab(textAlignment: .right, location: x, options: [:]))
        let totalWidth = x

        // Separator line
        let sepStyle = NSMutableParagraphStyle()
        sepStyle.maximumLineHeight = 1
        sepStyle.minimumLineHeight = 1
        let sepAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 1),
            .foregroundColor: UIColor.clear,
            .backgroundColor: separatorColor
        ]
        let sepStr = String(repeating: " ", count: max(1, Int(totalWidth / 2)))
        let separatorLine = NSAttributedString(string: sepStr + "\n", attributes: sepAttr)

        let hasHeader = !table.rows.isEmpty && table.rows[0].contains(where: { $0.isHeader })

        for (ri, row) in table.rows.enumerated() {
            let isHeaderRow = ri == 0 && hasHeader
            let bgColor = isHeaderRow ? headerBgColor : (ri % 2 == 0 ? rowBgEven : rowBgOdd)
            let font = isHeaderRow ? headerFont : tableFont
            let fgColor = isHeaderRow ? headerColor : baseColor

            let paraStyle = NSMutableParagraphStyle()
            paraStyle.tabStops = tabStops
            paraStyle.headIndent = 0
            paraStyle.firstLineHeadIndent = 0
            paraStyle.lineBreakMode = .byTruncatingTail
            // 2.0x line height for comfortable row spacing
            paraStyle.minimumLineHeight = tableLineH
            paraStyle.maximumLineHeight = tableLineH

            // Build tab-separated row string
            var parts: [String] = []
            var ci = 0
            for cell in row {
                parts.append(cell.text)
                // Add tab after each cell, but if colspan > 1, skip intermediate tabs
                let cols = min(cell.colspan, colCount - ci)
                for _ in 0..<cols {
                    if ci + 1 < colCount {
                        parts.append("\t")
                    }
                    ci += 1
                }
            }

            let rowStr = parts.joined() + "\n"
            // baselineOffset centres the text vertically inside the expanded line height.
            // Use ascender + descender (actual glyph height) rather than font.lineHeight
            // which includes leading — this keeps text centered at any multiplier.
            let glyphH = font.ascender + abs(font.descender)
            let rowBO = (tableLineH - glyphH) / 2.0
            let rowAttr = NSMutableAttributedString(string: rowStr, attributes: [
                .font: font,
                .foregroundColor: fgColor,
                .backgroundColor: bgColor,
                .paragraphStyle: paraStyle,
                .baselineOffset: rowBO
            ])

            if isHeaderRow && table.rows.count > 1 {
                rowAttr.append(separatorLine)
            }

            result.append(rowAttr)
        }

        return result
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 3 { return false }
        let stripped = trimmed.filter { $0 != " " }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
            && stripped.count >= 3
    }

    private static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 8
        case 2: return base + 5
        case 3: return base + 3
        case 4: return base + 1
        default: return base
        }
    }

    private static func mergedAttributes(
        base: [NSAttributedString.Key: Any],
        overrides: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var merged = base
        for (key, value) in overrides {
            merged[key] = value
        }
        return merged
    }
}

private enum OcrMathImages {
    private static var cache: [String: UIImage] = [:]

    static func image(latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat) -> UIImage? {
        let prepared = prepare(latex)
        let key = "\(display)|\(fontSize)|\(maxWidth)|\(prepared)"
        if let cached = cache[key] { return cached }
        guard let image = draw(prepared, display: display, fontSize: fontSize, maxWidth: maxWidth) else {
            return nil
        }
        cache[key] = image
        return image
    }

    private static func draw(_ latex: String, display: Bool, fontSize: CGFloat, maxWidth: CGFloat) -> UIImage? {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.mode = display ? .display : .text
        label.textAlignment = .left
        label.textColor = .black
        label.fontSize = fontSize
        label.latex = latex
        guard label.error == nil else {
            print("[OCR] math failed: \(label.error!.localizedDescription) :: \(latex.prefix(80))")
            return nil
        }
        var size = label.intrinsicContentSize
        if maxWidth > 0, size.width > maxWidth, size.width > 0 {
            label.fontSize = max(8, fontSize * maxWidth / size.width)
            size = label.intrinsicContentSize
        }
        guard size.width > 1, size.height > 1 else { return nil }
        let padded = CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4)
        label.frame = CGRect(origin: .zero, size: padded)
        label.layoutSubviews()
        guard let display = label.displayList else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: padded, format: format).image { ctx in
            let context = ctx.cgContext
            context.translateBy(x: 0, y: padded.height)
            context.scaleBy(x: 1, y: -1)
            display.draw(context)
        }
    }

    private static func prepare(_ latex: String) -> String {
        let flat = latex.replacingOccurrences(of: "\n", with: " ")
        return wrapCJK(rewriteArray(flat))
    }

    private static func rewriteArray(_ input: String) -> String {
        var result = ""
        var rest = input[...]
        let beginToken = "\\begin{array}"
        let endToken = "\\end{array}"
        while let begin = rest.range(of: beginToken) {
            result += rest[..<begin.lowerBound]
            let afterBegin = rest[begin.upperBound...]
            guard afterBegin.first == "{",
                  let specEnd = afterBegin.firstIndex(of: "}") else {
                result += beginToken
                rest = afterBegin
                continue
            }
            let spec = afterBegin[afterBegin.index(after: afterBegin.startIndex)..<specEnd]
            let cols = spec.filter { $0 == "l" || $0 == "c" || $0 == "r" }.count
            let afterSpec = afterBegin[afterBegin.index(after: specEnd)...]
            guard let end = afterSpec.range(of: endToken) else {
                result += rest[begin.lowerBound...]
                return result
            }
            var body = String(afterSpec[..<end.lowerBound])
            if cols <= 1, !body.contains("&") {
                while true {
                    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasSuffix("\\\\") {
                        body = String(trimmed.dropLast(2))
                    } else {
                        body = trimmed
                        break
                    }
                }
                result += "\\begin{gather}" + body + "\\end{gather}"
            } else {
                result += rest[begin.lowerBound..<end.upperBound]
            }
            rest = afterSpec[end.upperBound...]
        }
        result += rest
        return result
    }

    private static func wrapCJK(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i...].hasPrefix("\\text{") {
                let open = input.index(i, offsetBy: 5)
                guard let close = matchingBrace(input, open: open) else {
                    out += input[i...]
                    break
                }
                out += input[i...close]
                i = input.index(after: close)
                continue
            }
            if isHan(input[i]) {
                var j = i
                while j < input.endIndex, isHan(input[j]) {
                    j = input.index(after: j)
                }
                out += "\\text{"
                out += input[i..<j]
                out += "}"
                i = j
                continue
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }

    private static func matchingBrace(_ text: String, open: String.Index) -> String.Index? {
        guard open < text.endIndex, text[open] == "{" else { return nil }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 }
            else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}
