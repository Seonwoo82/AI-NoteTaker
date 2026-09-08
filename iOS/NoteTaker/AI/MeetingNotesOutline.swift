import SwiftUI

struct MeetingNotesOutline: View {
    let headings: [MarkdownDocument.Heading]
    let selectedBlockIndex: Int?
    let onSelect: (MarkdownDocument.Heading) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var showsAll = false
    private let previewCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Outline"))
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(headings.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Outline"))
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityIdentifier("ai-outline-toggle")
            .help(isExpanded ? String(localized: "Hide outline") : String(localized: "Show outline"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(showsAll ? headings : Array(headings.prefix(previewCount))) { heading in
                        OutlineRow(heading: heading, isSelected: selectedBlockIndex == heading.blockIndex) {
                            onSelect(heading)
                        }
                    }
                }

                if headings.count > previewCount {
                    Button(showsAll ? String(localized: "Show fewer sections") : String(localized: "Show all sections")) {
                        showsAll.toggle()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.leading, 11)
                    .padding(.top, 5)
                    .accessibilityIdentifier("ai-outline-show-all")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.appSeparator.opacity(0.35), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsAll)
    }
}

private struct OutlineRow: View {
    let heading: MarkdownDocument.Heading
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var title: AttributedString { MarkdownInlineFormatter.attributed(heading.text) }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(width: 3, height: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(isHovered || isSelected ? 0.8 : 0.3))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            #if os(iOS)
            .frame(minHeight: 44)
            #else
            .frame(minHeight: 30)
            #endif
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(isHovered ? 0.045 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(String(title.characters))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ai-outline-item-\(heading.blockIndex)")
    }
}
