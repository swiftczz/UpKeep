import XCTest

@testable import Upkeep

final class ReleaseNotesMarkdownTests: XCTestCase {
  func testHeadingsAndInlineFormatting() {
    let blocks = ReleaseNotesMarkdown.parse(
      "# Release\n\n## Fixes\n\n**Bold** and *italic* with `code`.")
    XCTAssertEqual(blocks.map(\.heading), [1, 2, nil])
    XCTAssertEqual(String(blocks[2].text.characters), "Bold and italic with code.")
    XCTAssertTrue(
      blocks[2].text.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
    XCTAssertTrue(
      blocks[2].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
  }

  func testNestedListsAndContinuationParagraphs() {
    let blocks = ReleaseNotesMarkdown.parse("1. First\n\n   More details\n\n   - Nested\n2. Second")
    XCTAssertEqual(blocks.map(\.marker), ["1.", "", "•", "2."])
    XCTAssertEqual(blocks.map(\.indent), [0, 0, 1, 0])
  }

  func testTaskListsRenderCheckedUncheckedAndUppercaseMarkers() {
    let blocks = ReleaseNotesMarkdown.parse("- [x] Done\n- [ ] Pending\n* [X] Finished\n+ Ordinary")
    XCTAssertEqual(blocks.map(\.taskChecked), [true, false, true, nil])
    XCTAssertEqual(
      blocks.map { String($0.text.characters) }, ["Done", "Pending", "Finished", "Ordinary"])
  }

  func testTasksPreserveFormattingLinksNestingAndContinuationParagraphs() {
    let blocks = ReleaseNotesMarkdown.parse(
      """
      - [x] **完成** [详情](changes)

        补充说明

        - [ ] `code` 待办
      1. [X] 有序任务
      """, baseURL: URL(string: "https://example.com/releases/"))
    XCTAssertEqual(blocks.map(\.taskChecked), [true, nil, false, true])
    XCTAssertEqual(blocks.map(\.indent), [0, 0, 1, 0])
    XCTAssertEqual(blocks[1].marker, "")
    XCTAssertTrue(
      blocks[0].text.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
    XCTAssertEqual(
      blocks[0].text.runs.compactMap(\.link).first?.absoluteString,
      "https://example.com/releases/changes")
    XCTAssertTrue(
      blocks[2].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    XCTAssertEqual(String(blocks[2].text.characters), "code 待办")
  }

  func testTaskSyntaxDoesNotChangeLiteralCodeEscapesOrLinks() {
    let blocks = ReleaseNotesMarkdown.parse(
      #"""
      [x] Ordinary paragraph

      - \[x] Escaped
      - `[x]` Code
      - **[x]** Bold literal
      - [x](https://example.com) Link
      - [x]suffix
      - [x]**missing space**
      - [y] Invalid
      - Text [x] later

      ```markdown
      - [x] Code block
      ```
      """#)
    XCTAssertTrue(blocks.allSatisfy { $0.taskChecked == nil })
    XCTAssertEqual(String(blocks[1].text.characters), "[x] Escaped")
    XCTAssertTrue(String(blocks.last!.text.characters).contains("- [x] Code block"))
  }

  func testQuotedAndEmptyTasksDoNotRepeatMarkersOnContinuation() {
    let blocks = ReleaseNotesMarkdown.parse(
      "> - [x] 完成\n> - [ ] 待办\n\n- [x] \n\n  Description\n\n- [ ]\tTabbed")
    XCTAssertEqual(blocks.compactMap(\.taskChecked), [true, false, true, false])
    XCTAssertTrue(blocks[0].quote)
    XCTAssertTrue(blocks[1].quote)
    XCTAssertEqual(blocks.last.map { String($0.text.characters) }, "Tabbed")
  }

  func testGitHubTablePreservesCellsAndRows() {
    let blocks = ReleaseNotesMarkdown.parse(
      "| Platform | Download |\n|---|---|\n| macOS | [DMG](https://example.com/app.dmg) |")
    XCTAssertEqual(blocks.count, 4)
    XCTAssertEqual(Set(blocks.compactMap(\.tableID)).count, 1)
    XCTAssertEqual(Set(blocks.compactMap(\.rowID)).count, 2)
    XCTAssertEqual(blocks.map(\.headerCell), [true, true, false, false])
    XCTAssertEqual(blocks.last?.text.link?.absoluteString, "https://example.com/app.dmg")
  }

  func testEmptyTableCellsKeepTheirColumnPositions() {
    let blocks = ReleaseNotesMarkdown.parse(
      "| A | B | C | D |\n|---|---|---|---|\n| One | | | Four |")
    let row = blocks.filter { !$0.headerCell }
    XCTAssertEqual(row.map(\.column), [0, 3])
    XCTAssertEqual(row.map(\.columnCount), [4, 4])
  }

  func testCodeAndQuotes() {
    let blocks = ReleaseNotesMarkdown.parse("> Note\n\n```swift\nlet text = \"**literal**\"\n```")
    XCTAssertTrue(blocks[0].quote)
    XCTAssertTrue(blocks[1].code)
    XCTAssertTrue(String(blocks[1].text.characters).contains("**literal**"))
  }

  func testLinksResolveRelativePathsAndRejectExecutableSchemes() {
    let blocks = ReleaseNotesMarkdown.parse(
      "[Notes](changes) [Bad](javascript:alert) [Local](file:///tmp/test)",
      baseURL: URL(string: "https://example.com/releases/"))
    let links = blocks.flatMap { $0.text.runs.compactMap(\.link) }
    XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/releases/changes"])
  }

  func testGitHubDetailsDoesNotDisplayRawHTMLOrDuplicateIdentities() {
    let blocks = ReleaseNotesMarkdown.parse(
      "Before\n\n<details>\n<summary><b>Full changelog</b></summary>\n\n## Added\n\n- Feature\n\n</details>\n\nAfter"
    )
    let texts = blocks.map { String($0.text.characters) }
    XCTAssertEqual(texts, ["Before", "Full changelog", "Added", "Feature", "After"])
    XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
  }

  func testPlainTextAndEmptyNotes() {
    XCTAssertEqual(
      String(ReleaseNotesMarkdown.parse("修复问题。\n\n• 优化性能。")[0].text.characters), "修复问题。")
    XCTAssertTrue(ReleaseNotesMarkdown.parse("").isEmpty)
  }

  func testDocumentPreservesParagraphOrderAndSparseTableColumns() {
    let document = ReleaseNotesMarkdown.Document(
      blocks: ReleaseNotesMarkdown.parse(
        "Before\n\n| A | B | C | D |\n|---|---|---|---|\n| One | | | Four |\n\nAfter"
      ))
    XCTAssertEqual(document.sections.count, 3)
    XCTAssertEqual(Set(document.sections.map(\.id)).count, 3)
    guard case .paragraph(let before) = document.sections[0].content,
      case .table(let rows) = document.sections[1].content,
      case .paragraph(let after) = document.sections[2].content
    else { return XCTFail("Expected paragraph, table, paragraph") }
    XCTAssertEqual(String(before.text.characters), "Before")
    XCTAssertEqual(String(after.text.characters), "After")
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows[0].isHeader)
    XCTAssertFalse(rows[1].isHeader)
    XCTAssertEqual(
      rows[1].cells.map { $0.map { String($0.text.characters) } }, ["One", nil, nil, "Four"])
  }
}
