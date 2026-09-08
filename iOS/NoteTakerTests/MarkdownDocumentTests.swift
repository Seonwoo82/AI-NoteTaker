import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

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

@Test("markdown headings with duplicate text remain distinct for navigation")
func markdownHeadingsWithDuplicateTextRemainDistinctForNavigation() {
    let source = """
    # Planning

    ## Decisions
    Ship the first decision.

    ## Decisions
    Ship the second decision.
    """

    let headings = MarkdownDocument(source).headings

    #expect(headings.count == 3)
    #expect(headings[1] != headings[2])
}

@Test("markdown headings expose stable block index identity and anchors")
func markdownHeadingsExposeStableBlockIndexIdentityAndAnchors() {
    let source = """
    # Planning

    Intro paragraph.

    ## Decisions
    Ship the first decision.

    ## Decisions
    Ship the second decision.
    """

    let headings = MarkdownDocument(source).headings

    #expect(headings.map(\.blockIndex) == [0, 2, 4])
    #expect(headings.map(\.id) == [0, 2, 4])
    #expect(MarkdownDocument.Anchor.block(headings[1].blockIndex) != .block(headings[2].blockIndex))
}

@Test("markdown outline falls back to h3 when no h2 sections exist")
func markdownOutlineFallsBackToH3WhenNoH2SectionsExist() {
    let source = """
    # Planning

    ### Risks
    Budget drift.

    #### Detail
    Keep watching scope.

    ### Actions
    Send the recap.
    """

    let outline = MarkdownDocument(source).outlineHeadings

    #expect(outline.map(\.level) == [3, 3])
    #expect(outline.map(\.text) == ["Risks", "Actions"])
    #expect(outline.map(\.blockIndex) == [1, 5])
}

@Test("markdown outline is empty for title-only documents")
func markdownOutlineIsEmptyForTitleOnlyDocuments() {
    let source = """
    # Planning

    Opening notes without sections.
    """

    #expect(MarkdownDocument(source).outlineHeadings == [])
}

@Test("markdown outline preserves every h2 section")
func markdownOutlinePreservesEveryH2Section() {
    let source = """
    # Planning

    ## One
    Notes.

    ## Two
    Notes.

    ## Three
    Notes.

    ## Four
    Notes.

    ## Five
    Notes.

    ## Six
    Notes.

    ## Seven
    Notes.
    """

    let outline = MarkdownDocument(source).outlineHeadings

    #expect(outline.map(\.text) == ["One", "Two", "Three", "Four", "Five", "Six", "Seven"])
    #expect(outline.count == 7)
}
