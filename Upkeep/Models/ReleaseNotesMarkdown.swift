import Foundation

/// Foundation parses Markdown; this model retains block structure for native layout.
enum ReleaseNotesMarkdown {
  struct Block: Identifiable, Equatable, Sendable {
    let id: Int
    var text = AttributedString()
    var heading: Int?
    var code = false
    var quote = false
    var marker: String?
    var indent = 0
    var tableID: Int?
    var rowID: Int?
    var headerCell = false
    var column = 0
    var columnCount = 0
  }

  struct Document: Equatable, Sendable {
    let sections: [Section]
    let blockCount: Int

    init(blocks: [Block]) {
      var sections: [Section] = []
      var index = 0
      while index < blocks.count {
        let block = blocks[index]
        guard let tableID = block.tableID else {
          sections.append(Section(id: block.id, content: .paragraph(block)))
          index += 1
          continue
        }

        var rows: [TableRow] = []
        while index < blocks.count, blocks[index].tableID == tableID {
          let cell = blocks[index]
          let rowID = cell.rowID ?? cell.id
          if rows.last?.id != rowID {
            rows.append(TableRow(
              id: rowID, cells: Array(repeating: nil, count: block.columnCount),
              isHeader: cell.headerCell
            ))
          }
          if rows[rows.count - 1].cells.indices.contains(cell.column) {
            rows[rows.count - 1].cells[cell.column] = cell
          }
          index += 1
        }
        sections.append(Section(id: tableID, content: .table(rows)))
      }
      self.sections = sections
      blockCount = blocks.count
    }
  }

  struct Section: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
      case paragraph(Block)
      case table([TableRow])
    }

    let id: Int
    let content: Content
  }

  struct TableRow: Identifiable, Equatable, Sendable {
    let id: Int
    var cells: [Block?]
    let isHeader: Bool
  }

  static func parse(_ source: String, baseURL: URL? = nil) -> [Block] {
    guard let parsed = try? AttributedString(markdown: source,
      options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible),
      baseURL: baseURL) else {
      return [Block(id: 0, text: AttributedString(source))]
    }
    var blocks: [Block] = []
    var markedItems = Set<Int>()
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let id = components.first?.identity ?? -(blocks.count + 1)
      var text = AttributedString(parsed[run.range])
      if run.inlinePresentationIntent?.contains(.blockHTML) == true {
        guard let content = ReleaseNotesHTML.text(String(text.characters)) else { continue }
        text = AttributedString(content)
      } else if run.inlinePresentationIntent?.contains(.inlineHTML) == true {
        continue
      }
      // Only open ordinary web/mail links. Markdown never executes HTML or scripts.
      if let link = text.link, !["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
        text.link = nil
      }
      text.presentationIntent = nil
      if blocks.last?.id == id {
        blocks[blocks.count - 1].text.append(text)
        continue
      }
      var block = Block(id: id, text: text)
      var item: (Int, Int)?
      var ordered = false
      var listCount = 0
      for component in components {
        switch component.kind {
        case .header(let level): block.heading = level
        case .codeBlock: block.code = true
        case .blockQuote: block.quote = true
        case .listItem(let ordinal):
          if item == nil { item = (component.identity, ordinal) }
        case .orderedList:
          if listCount == 0 { ordered = true }
          listCount += 1
        case .unorderedList: listCount += 1
        case .table(let columns):
          block.tableID = component.identity
          block.columnCount = columns.count
        case .tableCell(let column): block.column = column
        case .tableRow, .tableHeaderRow:
          block.rowID = component.identity
          if case .tableHeaderRow = component.kind { block.headerCell = true }
        default: break
        }
      }
      if let item {
        block.indent = max(0, listCount - 1)
        block.marker = markedItems.insert(item.0).inserted ? (ordered ? "\(item.1)." : "•") : ""
      }
      blocks.append(block)
    }
    if blocks.isEmpty && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return [Block(id: 0, text: AttributedString(source))]
    }
    return blocks
  }
}
