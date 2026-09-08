import Foundation
import SwiftUI

struct MarkdownDocumentView: View {
    let document: MarkdownDocument

    init(_ source: String) {
        document = MarkdownDocument(source)
    }

    init(document: MarkdownDocument) {
        self.document = document
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityIdentifier("ai-notes-document")
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(attributed(text))
                .font(font(for: level))
                .padding(.top, level == 1 ? 2 : 8)
        case .paragraph(let text):
            Text(attributed(text))
                .font(.body)
                .lineSpacing(3)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(attributed(item.text))
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
                        Text(attributed(item.text))
                    }
                }
            }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.isComplete ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(attributed(item.text))
                    }
                }
            }
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(attributed(text))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 2)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownTableRow(cells: headers, isHeader: true)
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        MarkdownTableRow(cells: row, isHeader: false)
                        Divider().opacity(0.6)
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                }
            }
        }
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func attributed(_ markdown: String) -> AttributedString {
        MarkdownInlineFormatter.attributed(markdown)
    }
}

private struct MarkdownTableRow: View {
    let cells: [String]
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(attributed(cell))
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .lineLimit(nil)
                    .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .border(.separator.opacity(0.35), width: 0.5)
            }
        }
    }

    private func attributed(_ markdown: String) -> AttributedString {
        MarkdownInlineFormatter.attributed(markdown)
    }
}
