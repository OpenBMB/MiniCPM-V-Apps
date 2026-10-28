//
//  OcrMarkdownUtils.swift
//  MiniCPM-V-demo
//
//  OCR text cleanup and markdown assembly.
//  Image placeholders are ![image]().
//

import Foundation

enum OcrMarkdownUtils {

    private static let textBlockLabels: Set<String> = [
        "text", "content", "abstract", "reference", "reference_content",
        "vertical_text", "vision_footnote", "algorithm", "header", "footer",
        "footnote", "aside_text",
    ]

    private static let failureMarkers = [
        "failed", "cuda out of memory", "outofmemoryerror", "enginecore", "traceback",
    ]

    // MARK: - Engine failure comments

    /// A failure HTML comment becomes empty text.
    /// Any other comment is kept, because the model may emit one on purpose.
    static func classifyEngineText(_ raw: String) -> String {
        let pattern = try? NSRegularExpression(
            pattern: #"^\s*<!--\s*(?<msg>.*?)\s*-->\s*$"#,
            options: [.dotMatchesLineSeparators])
        let range = NSRange(raw.startIndex..., in: raw)
        guard let pattern,
              let match = pattern.firstMatch(in: raw, options: [], range: range),
              match.range.location == range.location, match.range.length == range.length,
              let msgRange = Range(match.range(withName: "msg"), in: raw) else {
            return raw
        }
        let msg = String(raw[msgRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = msg.lowercased()
        if failureMarkers.contains(where: { lowered.contains($0) }) {
            return ""
        }
        return raw
    }

    // MARK: - Repetition

    static func truncateRepetitiveContent(_ content: String, minCount: Int = 50) -> String {
        if content.isEmpty || pyLen(content) < minCount { return content }
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return content }

        if !stripped.contains("\n") && pyLen(stripped) > 100 {
            let n = pyLen(stripped)
            let upper = n / 5
            if upper >= 8 {
                for unitLen in 8...upper {
                    let unit = pySlice(stripped, n - unitLen, n)
                    var count = 0
                    var pos = n - unitLen
                    while pos >= 0 && pySlice(stripped, pos, pos + unitLen) == unit {
                        count += 1
                        pos -= unitLen
                    }
                    if count >= 5 {
                        let start = n - count * unitLen
                        if Double(pyLen(unit) * count) > Double(n) * 0.5 {
                            return pySlice(stripped, 0, start)
                        }
                    }
                }
            }
        }

        if !stripped.contains("\n") && pyLen(stripped) > 10 {
            let n = pyLen(stripped)
            let upper = n / 2
            if upper >= 1 {
                for unitLen in 1...upper {
                    let unit = pySlice(stripped, 0, unitLen)
                    let count = n / unitLen
                    let tiled = String(repeating: unit, count: count)
                    if tiled == pySlice(stripped, 0, unitLen * count) {
                        if count >= 10 { return unit }
                        break
                    }
                }
            }
        }

        let lines = pySplitNewlines(stripped)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count >= 10 {
            var freq: [String: Int] = [:]
            var first: [String: Int] = [:]
            for (i, line) in lines.enumerated() {
                let s = String(line)
                if first[s] == nil { first[s] = i }
                freq[s, default: 0] += 1
            }
            if let best = freq.max(by: { a, b in
                if a.value != b.value { return a.value < b.value }
                return (first[a.key] ?? 0) > (first[b.key] ?? 0)
            }), best.value >= 10, Double(best.value) / Double(lines.count) >= 0.8 {
                return best.key
            }
        }
        return content
    }

    static func truncateRepetitiveSuffix(_ text: String) -> String {
        let pattern = try? NSRegularExpression(pattern: #"\S+"#)
        let full = NSRange(text.startIndex..., in: text)
        let matches = pattern?.matches(in: text, range: full) ?? []
        if matches.count < 18 { return text }
        let words: [(String, Int)] = matches.compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            return (String(text[r]).lowercased(), pyIndex(text, r.lowerBound))
        }
        if words.count < 18 { return text }
        var earliest = pyLen(text)
        let maxWindow = min(64, words.count / 3)
        if maxWindow >= 6 {
            for window in 6...maxWindow {
                let limit = words.count - window * 3 + 1
                if limit <= 0 { continue }
                for start in 0..<limit {
                    let first = words[start..<(start + window)].map(\.0)
                    let second = words[(start + window)..<(start + window * 2)].map(\.0)
                    let third = words[(start + window * 2)..<(start + window * 3)].map(\.0)
                    if first == second && first == third {
                        earliest = min(earliest, words[start].1)
                        break
                    }
                }
            }
        }
        if earliest < pyLen(text) {
            return rstrip(pySlice(text, 0, earliest))
        }
        return text
    }

    // MARK: - Formulas

    static func hasMixedInlineFormulaContent(_ content: String) -> Bool {
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return false }
        if fullMatch(inlineMathRE, stripped) { return false }
        let without = replace(inlineMathRE, in: stripped, with: "")
        return !without.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func repairDisplayFormula(_ content: String) -> String {
        var content = repairDisplayDollars(content)
        content = replace(emptyBracketRE, in: content, with: " ")
        return replaceSpan(displaySpanRE, in: content)
    }

    // MARK: - One crop

    static func postprocessContent(_ rawContent: String, outputFormat: String, label: String = "") -> String {
        var content = truncateRepetitiveContent(
            rawContent.trimmingCharacters(in: .whitespacesAndNewlines),
            minCount: label == "table" ? 5000 : 50)

        if outputFormat == "latex" {
            if label == "display_formula" {
                content = repairDisplayFormula(content)
            }
            for pair in [("$$", "$$"), ("$", "$"), ("\\(", "\\)"), ("\\[", "\\]")] {
                if content.hasPrefix(pair.0) && content.hasSuffix(pair.1) {
                    let start = content.index(content.startIndex, offsetBy: pair.0.count, limitedBy: content.endIndex) ?? content.endIndex
                    let end = content.index(content.endIndex, offsetBy: -pair.1.count, limitedBy: content.startIndex) ?? content.startIndex
                    content = start <= end
                        ? String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        : ""
                }
            }
            if label == "display_formula" {
                content = replace(displayBracketSepRE, in: content, with: "$$   $$")
                content = content.replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: "")
            }
            if label == "display_formula" || label == "inline_formula" {
                content = OcrLatexRepair.repair(content, label: label)
            }
        } else if outputFormat == "html" {
            if content.hasPrefix("```html") { content = String(content.dropFirst(7)) }
            if content.hasPrefix("```") { content = String(content.dropFirst(3)) }
            if content.hasSuffix("```") { content = String(content.dropLast(3)) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if label == "table" {
                let openCount = content.components(separatedBy: "<table").count - 1
                let closeCount = content.components(separatedBy: "</table>").count - 1
                if openCount > closeCount {
                    content += String(repeating: "</table>", count: openCount - closeCount)
                }
            }
        }
        return content
    }

    static func normalizeCropText(_ text: String, label: String) -> String {
        var out = truncateRepetitiveSuffix(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if label != "display_formula" {
            out = replace(inlineLatexRE, in: out) { match, source in
                guard let r = Range(match.range(at: 1), in: source) else { return match.matched(in: source) }
                return "$\(source[r].trimmingCharacters(in: .whitespacesAndNewlines))$"
            }
        } else {
            out = replace(displayBracketSepRE, in: out, with: "$$   $$")
            out = out.replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: "")
        }
        out = replace(spacesRE, in: out, with: " ")
        out = replace(blankLinesRE, in: out, with: "\n\n")
        if label == "table" || label == "chart" {
            let html = OcrOtsl.convert(out)
            if !html.isEmpty { return html }
        }
        return out
    }

    static func splitTextBlock(_ content: String, protectInlineMath: Bool = false) -> String {
        let lines = pySplitNewlines(content)
        var output: [String] = []
        var inCode = false, inDollar = false, inBracket = false, inHtml = false
        var inInlineDollar = false, inInlineParen = false
        var envDepth = 0

        func protected() -> Bool {
            inCode || inDollar || inBracket || inHtml || inInlineDollar || inInlineParen || envDepth > 0
        }
        func count(_ re: NSRegularExpression, _ line: String) -> Int {
            re.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
        }
        func afterFirst(_ line: String, _ token: String) -> String? {
            guard let r = line.range(of: token) else { return nil }
            return String(line[r.upperBound...])
        }

        for (index, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.hasPrefix("```") {
                output.append(line)
                inCode.toggle()
                continue
            }
            if inCode {
                output.append(line)
                continue
            }
            if stripped.lowercased().contains("<table") { inHtml = true }
            if inHtml {
                output.append(line)
                if stripped.lowercased().contains("</table>") { inHtml = false }
                continue
            }
            if isPipeRow(line) {
                output.append(line)
                let nextIsPipe = index + 1 < lines.count && isPipeRow(lines[index + 1])
                if !nextIsPipe && !(output.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.append("")
                }
                continue
            }

            let displayDollars = count(unescapedDisplayDollarRE, line)
            let bracketRest = afterFirst(line, "\\[")
            let bracketOpens = bracketRest != nil && !bracketRest!.contains("\\]")
            let inlineDollars = count(unescapedInlineDollarRE, line)
            let parenRest = afterFirst(line, "\\(")
            let parenOpens = parenRest != nil && !parenRest!.contains("\\)")
            let begins = count(beginEnvRE, line)
            let ends = count(endEnvRE, line)

            if protected() {
                output.append(line)
                if inDollar && displayDollars % 2 != 0 { inDollar = false }
                if inBracket && line.contains("\\]") { inBracket = false }
                if inInlineDollar && inlineDollars % 2 != 0 { inInlineDollar = false }
                if inInlineParen && line.contains("\\)") { inInlineParen = false }
                envDepth = max(0, envDepth + begins - ends)
                continue
            }

            let netEnv = begins - ends
            if displayDollars % 2 != 0 || bracketOpens || netEnv > 0 {
                output.append(line)
                inDollar = displayDollars % 2 == 1
                inBracket = bracketOpens
                envDepth = max(0, envDepth + netEnv)
                continue
            }
            if protectInlineMath && (inlineDollars % 2 != 0 || parenOpens) {
                output.append(line)
                inInlineDollar = inlineDollars % 2 == 1
                inInlineParen = parenOpens
                continue
            }
            if !stripped.isEmpty {
                if let last = output.last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.append("")
                }
                output.append(stripped)
                output.append("")
            }
        }
        let joined = output.joined(separator: "\n")
        return replace(manyNewlinesRE, in: joined, with: "\n\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    static func normalizeAndDedupe(_ blocks: [OcrBlock]) -> [OcrBlock] {
        var out: [OcrBlock] = []
        var seen = Set<DedupeKey>()
        for block in blocks.sorted(by: { $0.order < $1.order }) {
            var content = normalizeCropText(block.content, label: block.label)
            if textBlockLabels.contains(block.label) {
                content = splitTextBlock(content)
            } else if block.label == "inline_formula" && block.inlineFormulaMixed {
                content = splitTextBlock(content, protectInlineMath: true)
            }
            let key = DedupeKey(order: block.order, label: block.label, content: content)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(OcrBlock(
                label: block.label, content: content, order: block.order,
                x1: block.x1, y1: block.y1, x2: block.x2, y2: block.y2,
                score: block.score, inlineFormulaMixed: block.inlineFormulaMixed))
        }
        return out
    }

    // MARK: - Assembly

    struct OcrBlock {
        let label: String
        let content: String
        let order: Int
        let x1: Float
        let y1: Float
        let x2: Float
        let y2: Float
        let score: Float
        let inlineFormulaMixed: Bool

        init(label: String, content: String, order: Int,
             x1: Float, y1: Float, x2: Float, y2: Float, score: Float,
             inlineFormulaMixed: Bool = false) {
            self.label = label
            self.content = content
            self.order = order
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
            self.score = score
            self.inlineFormulaMixed = inlineFormulaMixed
        }
    }

    static func assembleMarkdown(blocks: [OcrBlock]) -> String {
        let ignore = OcrDefaultPrompts.ignoreLabels
        let titleFmt = OcrDefaultPrompts.titleFormat
        let formulaFmt = OcrDefaultPrompts.formulaFormat
        var parts: [String] = []
        for block in blocks.sorted(by: { $0.order < $1.order }) {
            let label = block.label
            let content = block.content
            if ignore.contains(label) { continue }
            if content.isEmpty && !["image", "header_image", "footer_image", "chart", "seal"].contains(label) {
                continue
            }
            if let fmt = titleFmt[label] {
                parts.append(fmt.replacingOccurrences(of: "{content}", with: content))
            } else if let fmt = formulaFmt[label] {
                if label == "inline_formula" && block.inlineFormulaMixed {
                    parts.append(content)
                } else {
                    parts.append(fmt.replacingOccurrences(of: "{content}", with: content))
                }
            } else if label == "table" {
                parts.append(OcrDefaultPrompts.tableFormat.replacingOccurrences(of: "{content}", with: content))
            } else if ["image", "header_image", "footer_image"].contains(label) {
                parts.append("![image]()")
            } else if label == "chart" {
                parts.append(content.isEmpty ? "![image]()"
                    : OcrDefaultPrompts.chartFormat.replacingOccurrences(of: "{content}", with: content))
            } else if label == "seal" {
                parts.append(content.isEmpty ? "![image]()"
                    : OcrDefaultPrompts.sealFormat.replacingOccurrences(of: "{content}", with: content))
            } else {
                parts.append(content)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Regex helpers

    private struct DedupeKey: Hashable {
        let order: Int
        let label: String
        let content: String
    }

    /// Python `str.split("\n")`: keep empty pieces, and do not split on `\r`.
    private static func pySplitNewlines(_ s: String) -> [String] {
        var parts: [[Unicode.Scalar]] = [[]]
        for scalar in s.unicodeScalars {
            if scalar == "\n" {
                parts.append([])
            } else {
                parts[parts.count - 1].append(scalar)
            }
        }
        return parts.map { String(String.UnicodeScalarView($0)) }
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped.filter { $0 == "|" }.count >= 2 && stripped.hasPrefix("|"))
            || (stripped.filter { $0 == "|" }.count >= 2 && stripped.contains("---"))
    }

    private static func pyLen(_ s: String) -> Int { s.unicodeScalars.count }

    private static func pyIndex(_ s: String, _ index: String.Index) -> Int {
        s.unicodeScalars.distance(from: s.startIndex, to: index)
    }

    private static func pySlice(_ s: String, _ start: Int, _ end: Int) -> String {
        let scalars = Array(s.unicodeScalars)
        let a = max(0, min(scalars.count, start))
        let b = max(a, min(scalars.count, end))
        return String(String.UnicodeScalarView(scalars[a..<b]))
    }

    private static func rstrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        return String(s[..<end])
    }

    private static func repairDisplayDollars(_ markdown: String) -> String {
        var tokens: [String] = []
        var rest = markdown[...]
        while let r = rest.range(of: "$$") {
            tokens.append(String(rest[..<r.lowerBound]))
            tokens.append("$$")
            rest = rest[r.upperBound...]
        }
        tokens.append(String(rest))

        var output: [String] = []
        var inDisplay = false
        for (index, token) in tokens.enumerated() {
            if token != "$$" {
                output.append(token)
                continue
            }
            let nextSegment = index + 1 < tokens.count ? tokens[index + 1] : ""
            let nextIsDelimiter = index + 2 < tokens.count && tokens[index + 2] == "$$"
            let hasLater = index + 2 < tokens.count && tokens[(index + 2)...].contains("$$")
            if !inDisplay {
                if (nextSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nextIsDelimiter) || !hasLater {
                    continue
                }
                output.append(token)
                inDisplay = true
            } else {
                output.append(token)
                inDisplay = false
            }
        }
        if inDisplay && !output.isEmpty { output.removeLast() }
        return output.joined()
    }

    private static func stripSpacingTokens(_ content: String) -> String {
        var content = replace(spacingCommandRE, in: content, with: "")
        content = replace(spacingPunctRE, in: content, with: "")
        content = content.replacingOccurrences(of: "\\ ", with: "")
        content = replace(hspaceRE, in: content, with: "")
        return content.replacingOccurrences(of: "~", with: "")
            .filter { !$0.isWhitespace && $0 != "{" && $0 != "}" }
    }

    private static func replaceSpan(_ re: NSRegularExpression, in source: String) -> String {
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return source }
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let whole = ns.substring(with: match.range)
            let isBracket = whole.hasPrefix("\\[")
            let bodyRange = isBracket ? match.range(at: 1) : match.range(at: 2)
            var body = bodyRange.location != NSNotFound ? ns.substring(with: bodyRange) : ""
            let stripped = rstrip(body)
            let trailing = String(body.dropFirst(stripped.count))
            if matchesTrailingBackslash(stripped) {
                body = String(stripped.dropLast()) + trailing
            }
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stripSpacingTokens(body).isEmpty {
                result += " "
            } else if isBracket {
                result += "\\[" + body + "\\]"
            } else {
                result += "$$" + body + "$$"
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    private static func matchesTrailingBackslash(_ s: String) -> Bool {
        trailingBackslashRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func fullMatch(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, options: .anchored, range: range) else { return false }
        return m.range.location == range.location && m.range.length == range.length
    }

    private static func replace(_ re: NSRegularExpression, in source: String, with template: String) -> String {
        let range = NSRange(source.startIndex..., in: source)
        return re.stringByReplacingMatches(in: source, range: range, withTemplate: template)
    }

    private static func replace(_ re: NSRegularExpression, in source: String,
                                _ body: (NSTextCheckingResult, String) -> String) -> String {
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return source }
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            result += body(match, source)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }
}

private extension NSTextCheckingResult {
    func matched(in source: String) -> String {
        guard let r = Range(range, in: source) else { return "" }
        return String(source[r])
    }
}

// Regexes live at file scope so the enum can use them while it is initializing.
private let displayBracketSepRE = try! NSRegularExpression(pattern: #"\\]\s*\\\["#)
private let inlineLatexRE = try! NSRegularExpression(pattern: #"\\\((.+?)\\\)"#)
private let emptyBracketRE = try! NSRegularExpression(pattern: #"\\\[\s*\\\]|\\\(\s*\\\)"#)
private let displaySpanRE = try! NSRegularExpression(
    pattern: #"\\\[(.*?)\\\]|\$\$(.*?)\$\$"#, options: .dotMatchesLineSeparators)
private let inlineMathRE = try! NSRegularExpression(
    pattern: #"(?<!\\)\$(?!\$)(?:[^$\n]|\\.)+?(?<!\\)\$(?!\$)|\\\([^\n]*?\\\)"#)
private let unescapedDisplayDollarRE = try! NSRegularExpression(pattern: #"(?<!\\)\$\$"#)
private let unescapedInlineDollarRE = try! NSRegularExpression(pattern: #"(?<!\\)(?<!\$)\$(?!\$)"#)
private let beginEnvRE = try! NSRegularExpression(pattern: #"\\begin\{"#)
private let endEnvRE = try! NSRegularExpression(pattern: #"\\end\{"#)
private let trailingBackslashRE = try! NSRegularExpression(pattern: #"(?<!\\)\\$"#)
private let spacingCommandRE = try! NSRegularExpression(
    pattern: #"\\(?:quad|qquad|enspace|thinspace|medspace|thickspace|negthinspace|negmedspace|negthickspace)(?![A-Za-z])"#)
private let spacingPunctRE = try! NSRegularExpression(pattern: #"\\[,;:!]"#)
private let hspaceRE = try! NSRegularExpression(pattern: #"\\(?:hspace|vspace)\s*\{[^{}]*\}"#)
private let spacesRE = try! NSRegularExpression(pattern: #"[ \t]+"#)
private let blankLinesRE = try! NSRegularExpression(pattern: #"\n{3,}"#)
private let manyNewlinesRE = try! NSRegularExpression(pattern: #"\n{3,}"#)

/// OTSL to HTML.
enum OcrOtsl {
    private static let nl = "<nl>"
    private static let fcel = "<fcel>"
    private static let ecel = "<ecel>"
    private static let lcel = "<lcel>"
    private static let ucel = "<ucel>"
    private static let xcel = "<xcel>"
    private static let tags: Set<String> = [nl, fcel, ecel, lcel, ucel, xcel]
    private static let findRE = try! NSRegularExpression(
        pattern: #"(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>).*?(?=(?:<fcel>|<ecel>|<nl>|<lcel>|<ucel>|<xcel>)|$)"#,
        options: .dotMatchesLineSeparators)
    private static let tokenRE = try! NSRegularExpression(
        pattern: #"(<nl>|<fcel>|<ecel>|<lcel>|<ucel>|<xcel>)"#)

    static func convert(_ otsl: String) -> String {
        let padded = pad(otsl)
        let (tokens, mixed) = extract(padded)
        let (cells, rows) = parse(texts: mixed, tokens: tokens)
        if cells.isEmpty { return "" }
        let cols = rows.map(\.count).max() ?? 0
        return export(cells: cells, rows: rows.count, cols: cols)
    }

    private static func pad(_ otsl: String) -> String {
        let otsl = otsl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !otsl.contains(nl) { return otsl + nl }
        var rowData: [(cells: [String], total: Int, minLen: Int)] = []
        for line in otsl.components(separatedBy: nl) where !line.isEmpty {
            let raw = matches(findRE, in: line)
            if raw.isEmpty { continue }
            var minLen = 0
            for (i, cell) in raw.enumerated() where cell.hasPrefix(fcel) { minLen = i + 1 }
            rowData.append((raw, raw.count, minLen))
        }
        if rowData.isEmpty { return nl }
        let globalMin = rowData.map(\.minLen).max() ?? 0
        let maxTotal = rowData.map(\.total).max() ?? 0
        var bestCost = Int.max
        var width = max(globalMin, maxTotal)
        if max(globalMin, maxTotal) >= globalMin {
            for w in globalMin...max(globalMin, maxTotal) {
                let cost = rowData.reduce(0) { $0 + abs($1.total - w) }
                if cost < bestCost {
                    bestCost = cost
                    width = w
                }
            }
        }
        let lines = rowData.map { row -> String in
            let cells = row.total > width
                ? Array(row.cells.prefix(width))
                : row.cells + Array(repeating: ecel, count: width - row.total)
            return cells.joined()
        }
        return lines.joined(separator: nl) + nl
    }

    private static func extract(_ s: String) -> ([String], [String]) {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        let tokens = tokenRE.matches(in: s, range: full).map { ns.substring(with: $0.range) }
        var parts: [String] = []
        var cursor = 0
        for match in tokenRE.matches(in: s, range: full) {
            if match.range.location > cursor {
                parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            parts.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { parts.append(ns.substring(from: cursor)) }
        return (tokens, parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func rowsOf(_ tokens: [String]) -> [[String]] {
        var rows: [[String]] = []
        var cur: [String] = []
        var open = false
        for token in tokens {
            if token == nl {
                if open {
                    rows.append(cur)
                    cur = []
                    open = false
                }
            } else {
                cur.append(token)
                open = true
            }
        }
        if open { rows.append(cur) }
        return rows
    }

    private static func parse(texts input: [String], tokens: [String]) -> ([(text: String, row: Int, col: Int, rowSpan: Int, colSpan: Int)], [[String]]) {
        var splitRows = rowsOf(tokens)
        var texts = input
        if !splitRows.isEmpty {
            let maxCols = splitRows.map(\.count).max() ?? 0
            for i in splitRows.indices {
                while splitRows[i].count < maxCols { splitRows[i].append(ecel) }
            }
            var rebuilt: [String] = []
            var textIdx = 0
            for row in splitRows {
                for token in row {
                    rebuilt.append(token)
                    if textIdx < texts.count && texts[textIdx] == token {
                        textIdx += 1
                        if textIdx < texts.count && !tags.contains(texts[textIdx]) {
                            rebuilt.append(texts[textIdx])
                            textIdx += 1
                        }
                    }
                }
                rebuilt.append(nl)
                if textIdx < texts.count && texts[textIdx] == nl { textIdx += 1 }
            }
            texts = rebuilt
        }

        func countRight(_ c: Int, _ r: Int, _ which: Set<String>) -> Int {
            var span = 0
            var ci = c
            while ci < splitRows[r].count && which.contains(splitRows[r][ci]) {
                ci += 1
                span += 1
            }
            return span
        }
        func countDown(_ c: Int, _ r: Int, _ which: Set<String>) -> Int {
            var span = 0
            var ri = r
            while ri < splitRows.count && c < splitRows[ri].count && which.contains(splitRows[ri][c]) {
                ri += 1
                span += 1
            }
            return span
        }

        var cells: [(text: String, row: Int, col: Int, rowSpan: Int, colSpan: Int)] = []
        var rIdx = 0
        var cIdx = 0
        for (i, text) in texts.enumerated() {
            if text == fcel || text == ecel {
                var rowSpan = 1
                var colSpan = 1
                var rightOffset = 1
                var cellText = ""
                if text != ecel {
                    cellText = i + 1 < texts.count ? texts[i + 1] : ""
                    rightOffset = 2
                }
                let nextRight = i + rightOffset < texts.count ? texts[i + rightOffset] : ""
                var nextBottom = ""
                if rIdx + 1 < splitRows.count && cIdx < splitRows[rIdx + 1].count {
                    nextBottom = splitRows[rIdx + 1][cIdx]
                }
                if nextRight == lcel || nextRight == xcel {
                    colSpan += countRight(cIdx + 1, rIdx, [lcel, xcel])
                }
                if nextBottom == ucel || nextBottom == xcel {
                    rowSpan += countDown(cIdx, rIdx + 1, [ucel, xcel])
                }
                cells.append((cellText.trimmingCharacters(in: .whitespacesAndNewlines), rIdx, cIdx, rowSpan, colSpan))
            }
            if text == fcel || text == ecel || text == lcel || text == ucel || text == xcel { cIdx += 1 }
            if text == nl { rIdx += 1; cIdx = 0 }
        }
        return (cells, splitRows)
    }

    private static func export(cells: [(text: String, row: Int, col: Int, rowSpan: Int, colSpan: Int)],
                               rows: Int, cols: Int) -> String {
        if cells.isEmpty { return "" }
        var grid = Array(repeating: Array(repeating: (text: "", row: 0, col: 0, rowSpan: 1, colSpan: 1), count: cols), count: rows)
        for i in 0..<rows {
            for j in 0..<cols { grid[i][j] = ("", i, j, 1, 1) }
        }
        for cell in cells {
            for i in min(cell.row, rows)..<min(cell.row + cell.rowSpan, rows) {
                for j in min(cell.col, cols)..<min(cell.col + cell.colSpan, cols) {
                    grid[i][j] = cell
                }
            }
        }
        var body = ""
        for i in 0..<rows {
            body += "<tr>"
            for j in 0..<cols {
                let cell = grid[i][j]
                if cell.row != i || cell.col != j { continue }
                let content = htmlEscape(cell.text.trimmingCharacters(in: .whitespacesAndNewlines))
                var open = "td"
                if cell.rowSpan > 1 { open += " rowspan=\"\(cell.rowSpan)\"" }
                if cell.colSpan > 1 { open += " colspan=\"\(cell.colSpan)\"" }
                body += "<\(open)>\(content)</td>"
            }
            body += "</tr>"
        }
        return "<table>\(body)</table>"
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    private static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

// MARK: - LaTeX formula repair

/// Pure string to string repairs for the LaTeX the model emits.
/// Port of the SDK's `postprocess/latex_repair.py` (itself from MinerU).
enum OcrLatexRepair {

    private static let leftRE = try! NSRegularExpression(
        pattern: #"(\\left)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[\{\}|.]|[()\[\]\{\}/|.])?"#)
    private static let rightRE = try! NSRegularExpression(
        pattern: #"(\\right)(?![a-zA-Z])(\\(?:lceil|rceil|lfloor|rfloor|backslash|uparrow|downarrow|Uparrow|Downarrow|langle|rangle)|\\[\{\}|.]|[()\[\]\{\}/|.])?"#)
    private static let leftCountRE = try! NSRegularExpression(pattern: #"\\left(?![a-zA-Z])"#)
    private static let rightCountRE = try! NSRegularExpression(pattern: #"\\right(?![a-zA-Z])"#)
    private static let leftRightRemoveRE = try! NSRegularExpression(
        pattern: #"\\left(?![a-zA-Z])\.?|\\right(?![a-zA-Z])\.?"#)

    private static let envTypes = [
        "array", "matrix", "pmatrix", "bmatrix", "vmatrix",
        "Bmatrix", "Vmatrix", "cases", "aligned", "gathered",
        "align", "align*",
    ]
    private static let envBegin = Dictionary(uniqueKeysWithValues: envTypes.map {
        ($0, try! NSRegularExpression(pattern: #"\\begin\{"# + NSRegularExpression.escapedPattern(for: $0) + #"\}"#))
    })
    private static let envEnd = Dictionary(uniqueKeysWithValues: envTypes.map {
        ($0, try! NSRegularExpression(pattern: #"\\end\{"# + NSRegularExpression.escapedPattern(for: $0) + #"\}"#))
    })
    private static let envFmt = Dictionary(uniqueKeysWithValues: envTypes.map {
        ($0, try! NSRegularExpression(
            pattern: #"\\begin\{"# + NSRegularExpression.escapedPattern(for: $0) + #"\}\{([^}]*)\}"#))
    })

    private static let mathringRE = try! NSRegularExpression(
        pattern: #"\\mathring(?!\s*\{)\s*(\\mathrm\s*\{[^{}]*\})"#)
    private static let duplicateArrayCloseRE = try! NSRegularExpression(
        pattern: #"(\\end\{array\}\s*\\right\.\s*){2,}"#)
    private static let duplicateBracketCloseRE = try! NSRegularExpression(
        pattern: #"(\\\]\s*){2,}"#)
    private static let trailingBackslashRE = try! NSRegularExpression(pattern: #"\\+$"#)

    /// Full repair chain. Safe on any string; returns the input unchanged when
    /// nothing looks broken.
    static func repair(_ s: String, label: String = "") -> String {
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }

        var out = fixUnbalancedBraces(s)

        let isDisplay = label == "display_formula" || label.isEmpty
        out = fixLeftRight(out, fixDelimiter: isDisplay)

        out = fixEnvironments(out)
        out = removeDuplicateClosures(out)
        return removeTrailingBackslashes(out)
    }

    // MARK: - Braces

    private static func isEscaped(_ chars: [Character], _ pos: Int) -> Bool {
        var count = 0
        var j = pos - 1
        while j >= 0 && chars[j] == "\\" {
            count += 1
            j -= 1
        }
        return count % 2 == 1
    }

    /// Drop `{` / `}` that have no partner.
    static func fixUnbalancedBraces(_ s: String) -> String {
        let chars = Array(s)
        var stack: [Int] = []
        var unmatched = Set<Int>()
        for (i, ch) in chars.enumerated() {
            guard ch == "{" || ch == "}" else { continue }
            if isEscaped(chars, i) { continue }
            if ch == "{" {
                stack.append(i)
            } else if let _ = stack.popLast() {
                // matched
            } else {
                unmatched.insert(i)
            }
        }
        unmatched.formUnion(stack)
        if unmatched.isEmpty { return s }
        var out = ""
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() where !unmatched.contains(i) {
            out.append(ch)
        }
        return out
    }

    // MARK: - \left / \right

    /// Index of the `}` that closes the group opened at `depth`.
    private static func findGroupEnd(_ chars: [Character], from pos: Int, depth: Int) -> Int {
        var current = depth
        var i = pos
        while i < chars.count {
            if chars[i] == "{" && !isEscaped(chars, i) {
                current += 1
            } else if chars[i] == "}" && !isEscaped(chars, i) {
                current -= 1
                if current < depth { return i }
            }
            i += 1
        }
        return -1
    }

    /// Move a `\right` that sits outside its `\left`'s brace group to just
    /// before that group's closing brace.
    private static func fixLeftRightPairs(_ s: String) -> String {
        let chars = Array(s)
        var braceStack: [Int] = []
        var leftStack: [(pos: Int, depth: Int)] = []
        var adjustments: [(start: Int, end: Int, target: Int)] = []

        var i = 0
        while i < chars.count {
            if i > 0 && isEscaped(chars, i) {
                i += 1
                continue
            }
            if hasPrefix(chars, at: i, #"\left"#),
               i + 5 < chars.count, !chars[i + 5].isLetter {
                leftStack.append((i, braceStack.count))
                i += 6
                continue
            }
            if hasPrefix(chars, at: i, #"\right"#),
               i + 6 < chars.count, !chars[i + 6].isLetter {
                if let left = leftStack.popLast(), left.depth != braceStack.count {
                    let target = findGroupEnd(chars, from: left.pos, depth: left.depth)
                    if target != -1 {
                        adjustments.append((i, i + 7, target))
                    }
                }
                i += 7
                continue
            }
            if chars[i] == "{" && !isEscaped(chars, i) {
                braceStack.append(i)
            } else if chars[i] == "}" && !isEscaped(chars, i) {
                let _ = braceStack.popLast()
            }
            i += 1
        }

        if adjustments.isEmpty { return s }

        var result = chars
        for adj in adjustments.sorted(by: { $0.start > $1.start }) {
            let rightPart = Array(result[adj.start..<adj.end])
            result.removeSubrange(adj.start..<adj.end)
            result.insert(contentsOf: rightPart, at: min(adj.target, result.count))
        }
        return String(result)
    }

    private static func hasPrefix(_ chars: [Character], at index: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard index + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[index + k] != p[k] { return false }
        return true
    }

    /// Balance `\left` / `\right`. Unequal counts fall back to stripping both.
    static func fixLeftRight(_ s: String, fixDelimiter: Bool = true) -> String {
        var out = s
        if fixDelimiter {
            out = sub(leftRE, in: out) { match, source in
                let cmd = group(match, 1, source)
                let delim = group(match, 2, source)
                return delim.isEmpty ? cmd + "." : match.matched(in: source)
            }
            out = sub(rightRE, in: out) { match, source in
                let cmd = group(match, 1, source)
                let delim = group(match, 2, source)
                return delim.isEmpty ? cmd + "." : match.matched(in: source)
            }
        }

        let leftCount = count(leftCountRE, in: out)
        let rightCount = count(rightCountRE, in: out)
        if leftCount == rightCount {
            return fixLeftRightPairs(out)
        }
        let range = NSRange(out.startIndex..., in: out)
        return leftRightRemoveRE.stringByReplacingMatches(in: out, range: range, withTemplate: "")
    }

    // MARK: - Environments

    /// Pad missing `\begin{env}` / `\end{env}` so every env is balanced.
    static func fixEnvironments(_ s: String) -> String {
        var out = s
        for env in envTypes {
            let beginCount = count(envBegin[env]!, in: out)
            let endCount = count(envEnd[env]!, in: out)
            if beginCount == endCount { continue }
            if endCount > beginCount {
                let missing = endCount - beginCount
                let fmt = envFmt[env]!.firstMatch(in: out, range: NSRange(out.startIndex..., in: out))
                    .flatMap { group($0, 1, out) }
                let fmtStr = fmt.map { "{" + $0 + "}" } ?? (env == "array" ? "{c}" : "")
                out = String(repeating: #"\begin{"# + env + "}" + fmtStr + " ", count: missing) + out
            } else {
                let missing = beginCount - endCount
                out += String(repeating: " " + #"\end{"# + env + "}", count: missing)
            }
        }
        return out
    }

    // MARK: - Misc

    /// Wrap a bare `\mathrm{...}` argument of `\mathring` in braces.
    static func fixMathringArguments(_ s: String) -> String {
        sub(mathringRE, in: s) { match, source in
            #"\mathring{"# + group(match, 1, source) + "}"
        }
    }

    static func removeDuplicateClosures(_ s: String) -> String {
        // 替换模板里反斜杠是转义符，要写两层才输出一个。
        var out = replacement(duplicateArrayCloseRE, in: s, with: #"\\end{array} \\right."#)
        out = replacement(duplicateBracketCloseRE, in: out, with: #"\\]"#)
        return out
    }

    /// Strip trailing lone backslashes that would break rendering.
    static func removeTrailingBackslashes(_ s: String) -> String {
        replacement(trailingBackslashRE, in: s, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex helpers

    private static func count(_ re: NSRegularExpression, in s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func replacement(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func sub(_ re: NSRegularExpression, in source: String,
                            _ body: (NSTextCheckingResult, String) -> String) -> String {
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return source }
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            result += body(match, source)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
        guard index < match.numberOfRanges else { return "" }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let r = Range(range, in: source) else { return "" }
        return String(source[r])
    }
}
