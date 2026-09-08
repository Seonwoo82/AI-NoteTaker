import Foundation
import Testing
@testable import NoteTaker

@Test("AI Markdown keeps emphasis but cannot activate links or local-file URLs")
func markdownInlineLinksAreInert() {
    let text = MarkdownInlineFormatter.attributed("**Important** [remote](https://example.com) [local](file:///tmp/example)")
    #expect(text.runs.allSatisfy { $0.link == nil })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(String(text.characters).contains("remote"))
}

@Test("markdown document parses headings tables tasks and fenced code")
func markdownDocumentParsesRichMeetingOutput() {
    let source = """
    # Weekly Sync

    Opening paragraph with **bold** and [notes](https://example.com).

    - [x] Ship parser
    - [ ] Polish UI
    1. First decision
    2. Second decision

    | Owner | Task |
    | --- | --- |
    | Mina | Follow up |

    > Keep prior notes visible while regenerating.

    ```swift
    let sample = "inert"
    ```
    """

    let document = MarkdownDocument(source)

    #expect(document.blocks == [
        .heading(level: 1, text: "Weekly Sync"),
        .paragraph("Opening paragraph with **bold** and [notes](https://example.com)."),
        .taskList([
            .init(text: "Ship parser", isComplete: true),
            .init(text: "Polish UI", isComplete: false)
        ]),
        .orderedList([
            .init(number: 1, text: "First decision"),
            .init(number: 2, text: "Second decision")
        ]),
        .table(
            headers: ["Owner", "Task"],
            rows: [["Mina", "Follow up"]]
        ),
        .blockquote("Keep prior notes visible while regenerating."),
        .codeBlock(language: "swift", code: "let sample = \"inert\"")
    ])
}

@Test("markdown document preserves malformed table and unclosed fence as inert text")
func markdownDocumentPreservesMalformedInput() {
    let source = """
    | Missing | Divider |
    | Still | Text |

    ```json
    {"ok": true}
    """

    let document = MarkdownDocument(source)

    #expect(document.blocks == [
        .paragraph("| Missing | Divider |\n| Still | Text |"),
        .codeBlock(language: "json", code: "{\"ok\": true}")
    ])
}
