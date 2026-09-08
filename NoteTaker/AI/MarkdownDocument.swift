import Foundation

nonisolated enum MarkdownInlineFormatter {
    static func attributed(_ markdown: String) -> AttributedString {
        var value = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for range in value.runs.map(\.range) { value[range].link = nil }
        return value
    }
}

nonisolated struct MarkdownDocument: Equatable, Sendable {
    let blocks: [Block]

    init(_ source: String) {
        var parser = MarkdownDocumentParser(source: source)
        blocks = parser.parse()
    }
}

nonisolated extension MarkdownDocument {
    var headings: [Heading] {
        blocks.enumerated().compactMap { blockIndex, block in
            guard case .heading(let level, let text) = block else { return nil }
            return Heading(blockIndex: blockIndex, level: level, text: text)
        }
    }

    var outlineHeadings: [Heading] {
        let candidates = headings.filter { $0.level >= 2 }
        guard let outlineLevel = candidates.map(\.level).min() else { return [] }
        return candidates.filter { $0.level == outlineLevel }
    }

    enum Anchor: Hashable, Sendable {
        case block(Int)
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedList([ListItem])
        case orderedList([OrderedListItem])
        case taskList([TaskListItem])
        case blockquote(String)
        case codeBlock(language: String?, code: String)
        case table(headers: [String], rows: [[String]])
    }

    struct ListItem: Equatable, Sendable {
        let text: String
        init(text: String) { self.text = text }
    }

    struct OrderedListItem: Equatable, Sendable {
        let number: Int
        let text: String
        init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    struct TaskListItem: Equatable, Sendable {
        let text: String
        let isComplete: Bool
        init(text: String, isComplete: Bool) {
            self.text = text
            self.isComplete = isComplete
        }
    }

    struct Heading: Equatable, Identifiable, Sendable {
        let blockIndex: Int
        var id: Int { blockIndex }
        let level: Int
        let text: String
    }
}

nonisolated private struct MarkdownDocumentParser {
    let lines: [String]
    var index = 0

    init(source: String) {
        lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    mutating func parse() -> [MarkdownDocument.Block] {
        var blocks: [MarkdownDocument.Block] = []

        while index < lines.count {
            if currentLine.trimmed.isEmpty {
                index += 1
                continue
            }

            if let code = parseCodeBlock() {
                blocks.append(code)
            } else if let heading = parseHeading() {
                blocks.append(heading)
            } else if let table = parseTable() {
                blocks.append(table)
            } else if let tasks = parseTaskList() {
                blocks.append(tasks)
            } else if let ordered = parseOrderedList() {
                blocks.append(ordered)
            } else if let unordered = parseUnorderedList() {
                blocks.append(unordered)
            } else if let quote = parseBlockquote() {
                blocks.append(quote)
            } else {
                blocks.append(parseParagraph())
            }
        }

        return blocks
    }

    private var currentLine: String { lines[index] }

    private mutating func parseHeading() -> MarkdownDocument.Block? {
        let line = currentLine.trimmed
        guard line.hasPrefix("#") else { return nil }
        let marker = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(marker.count),
              line.dropFirst(marker.count).first == " " else {
            return nil
        }
        index += 1
        return .heading(level: marker.count, text: String(line.dropFirst(marker.count + 1)).trimmed)
    }

    private mutating func parseCodeBlock() -> MarkdownDocument.Block? {
        let line = currentLine.trimmed
        guard line.hasPrefix("```") else { return nil }
        let language = String(line.dropFirst(3)).trimmed.nilIfEmpty
        index += 1

        var codeLines: [String] = []
        while index < lines.count {
            let next = lines[index]
            if next.trimmed.hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(next)
            index += 1
        }

        return .codeBlock(language: language, code: codeLines.joined(separator: "\n"))
    }

    private mutating func parseTable() -> MarkdownDocument.Block? {
        guard index + 1 < lines.count,
              isTableRow(lines[index]),
              isDividerRow(lines[index + 1]) else {
            return nil
        }

        let headers = tableCells(lines[index])
        index += 2
        var rows: [[String]] = []
        while index < lines.count, isTableRow(lines[index]) {
            rows.append(tableCells(lines[index]))
            index += 1
        }
        return .table(headers: headers, rows: rows)
    }

    private mutating func parseTaskList() -> MarkdownDocument.Block? {
        guard let first = taskItem(currentLine) else { return nil }
        var items = [first]
        index += 1
        while index < lines.count, let item = taskItem(lines[index]) {
            items.append(item)
            index += 1
        }
        return .taskList(items)
    }

    private mutating func parseOrderedList() -> MarkdownDocument.Block? {
        guard let first = orderedItem(currentLine) else { return nil }
        var items = [first]
        index += 1
        while index < lines.count, let item = orderedItem(lines[index]) {
            items.append(item)
            index += 1
        }
        return .orderedList(items)
    }

    private mutating func parseUnorderedList() -> MarkdownDocument.Block? {
        guard let first = unorderedItem(currentLine) else { return nil }
        var items = [first]
        index += 1
        while index < lines.count, let item = unorderedItem(lines[index]) {
            items.append(item)
            index += 1
        }
        return .unorderedList(items)
    }

    private mutating func parseBlockquote() -> MarkdownDocument.Block? {
        guard currentLine.trimmed.hasPrefix(">") else { return nil }
        var quoteLines: [String] = []
        while index < lines.count {
            let line = lines[index].trimmed
            guard line.hasPrefix(">") else { break }
            quoteLines.append(String(line.dropFirst()).trimmed)
            index += 1
        }
        return .blockquote(quoteLines.joined(separator: "\n"))
    }

    private mutating func parseParagraph() -> MarkdownDocument.Block {
        var paragraphLines: [String] = []
        while index < lines.count {
            let line = currentLine
            if line.trimmed.isEmpty { break }
            if !paragraphLines.isEmpty, startsBlock(line) { break }
            paragraphLines.append(line)
            index += 1
        }
        return .paragraph(paragraphLines.map(\.trimmed).joined(separator: "\n"))
    }

    private func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmed
        return trimmed.hasPrefix("```")
            || parseableHeading(trimmed)
            || taskItem(line) != nil
            || orderedItem(line) != nil
            || unorderedItem(line) != nil
            || trimmed.hasPrefix(">")
            || (index + 1 < lines.count && isTableRow(line) && isDividerRow(lines[index + 1]))
    }

    private func parseableHeading(_ line: String) -> Bool {
        let marker = line.prefix(while: { $0 == "#" })
        return (1...6).contains(marker.count) && line.dropFirst(marker.count).first == " "
    }

    private func unorderedItem(_ line: String) -> MarkdownDocument.ListItem? {
        let trimmed = line.trimmed
        guard trimmed.count > 2,
              ["- ", "* "].contains(String(trimmed.prefix(2))),
              taskItem(line) == nil else {
            return nil
        }
        return .init(text: String(trimmed.dropFirst(2)).trimmed)
    }

    private func orderedItem(_ line: String) -> MarkdownDocument.OrderedListItem? {
        let trimmed = line.trimmed
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty,
              trimmed.dropFirst(digits.count).hasPrefix(". "),
              let number = Int(digits) else {
            return nil
        }
        return .init(number: number, text: String(trimmed.dropFirst(digits.count + 2)).trimmed)
    }

    private func taskItem(_ line: String) -> MarkdownDocument.TaskListItem? {
        let trimmed = line.trimmed
        guard trimmed.hasPrefix("- ["),
              trimmed.count > 6 else {
            return nil
        }
        let marker = trimmed.dropFirst(3).prefix(1).lowercased()
        guard trimmed.dropFirst(4).hasPrefix("] "),
              marker == "x" || marker == " " else {
            return nil
        }
        return .init(text: String(trimmed.dropFirst(6)).trimmed, isComplete: marker == "x")
    }

    private func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmed
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && tableCells(trimmed).count > 1
    }

    private func isDividerRow(_ line: String) -> Bool {
        guard isTableRow(line) else { return false }
        return tableCells(line).allSatisfy { cell in
            let trimmed = cell.trimmed
            return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmed
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map(\.trimmed)
    }
}

nonisolated private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
