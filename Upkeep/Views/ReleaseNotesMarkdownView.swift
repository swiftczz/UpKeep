import SwiftUI

struct ReleaseNotesMarkdownView: View {
  let source: String
  let baseURL: URL?
  @State private var blocks: [ReleaseNotesMarkdown.Block] = []

  private struct Section: Identifiable {
    let id: Int
    var blocks: [ReleaseNotesMarkdown.Block]
  }

  private var sections: [Section] {
    var result: [Section] = []
    for block in blocks {
      let id = block.tableID ?? block.id
      if block.tableID != nil && result.last?.id == id {
        result[result.count - 1].blocks.append(block)
      } else {
        result.append(Section(id: id, blocks: [block]))
      }
    }
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(sections) { section in
        if section.blocks.first?.tableID != nil {
          table(section.blocks)
        } else if let block = section.blocks.first {
          paragraph(block)
        }
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: source + (baseURL?.absoluteString ?? "")) {
      blocks = ReleaseNotesMarkdown.parse(source, baseURL: baseURL)
    }
  }

  @ViewBuilder
  private func paragraph(_ block: ReleaseNotesMarkdown.Block) -> some View {
    if block.code {
      ScrollView(.horizontal) {
        Text(block.text)
          .font(.system(.body, design: .monospaced))
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    } else {
      HStack(alignment: .top, spacing: 8) {
        if block.quote {
          RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
        }
        if let marker = block.marker {
          Text(marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
        }
        Text(block.text)
          .font(font(for: block.heading))
          .lineSpacing(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.leading, CGFloat(block.indent) * 18)
      .padding(.top, block.heading == nil ? 0 : 5)
    }
  }

  private func font(for heading: Int?) -> Font {
    switch heading {
    case 1: .title2.bold()
    case 2: .title3.bold()
    case .some: .headline
    case nil: .body
    }
  }

  private func table(_ cells: [ReleaseNotesMarkdown.Block]) -> some View {
    var rows: [Section] = []
    for cell in cells {
      let id = cell.rowID ?? cell.id
      if rows.last?.id == id {
        rows[rows.count - 1].blocks.append(cell)
      } else {
        rows.append(Section(id: id, blocks: [cell]))
      }
    }
    return ScrollView(.horizontal) {
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(rows) { row in
          GridRow {
            ForEach(0..<(cells.first?.columnCount ?? 0), id: \.self) { column in
              let cell = row.blocks.first { $0.column == column }
              let header = row.blocks.first?.headerCell == true
              Text(cell?.text ?? AttributedString(" "))
                .font(header ? .headline : .body)
                .frame(minWidth: 80, maxWidth: 320, alignment: .leading)
                .padding(8)
                .background(header ? Color.secondary.opacity(0.12) : .clear)
                .overlay(alignment: .bottom) { Divider() }
            }
          }
        }
      }
    }
  }
}
