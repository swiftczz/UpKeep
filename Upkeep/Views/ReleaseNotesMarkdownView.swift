import SwiftUI

struct ReleaseNotesMarkdownView: View {
  let source: String
  let baseURL: URL?

  var body: some View {
    let request = ReleaseNotesCache.Request(source: source, baseURL: baseURL)
    ReleaseNotesContentView(request: request)
      .id(request)
  }
}

private struct ReleaseNotesContentView: View {
  let request: ReleaseNotesCache.Request
  @State private var document: ReleaseNotesMarkdown.Document?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 7) {
      if let document {
        ForEach(document.sections) { section in
          ReleaseNotesSectionView(section: section)
        }
      } else {
        ProgressView("正在加载更新说明…")
          .controlSize(.small)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      await loadDocument()
    }
  }

  private func loadDocument() async {
    guard let loaded = try? await ReleaseNotesCache.shared.document(for: request),
      !Task.isCancelled
    else { return }
    document = loaded
  }
}

private struct ReleaseNotesSectionView: View {
  let section: ReleaseNotesMarkdown.Section

  var body: some View {
    switch section.content {
    case .paragraph(let block):
      ReleaseNotesParagraphView(block: block)
    case .table(let rows):
      ReleaseNotesTableView(rows: rows)
    }
  }
}

private struct ReleaseNotesParagraphView: View {
  let block: ReleaseNotesMarkdown.Block

  var body: some View {
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
}

private struct ReleaseNotesTableView: View {
  let rows: [ReleaseNotesMarkdown.TableRow]

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(rows) { row in
          GridRow {
            ForEach(row.cells.indices, id: \.self) { column in
              let cell = row.cells[column]
              Text(cell?.text ?? AttributedString(" "))
                .font(row.isHeader ? .headline : .body)
                .frame(minWidth: 80, maxWidth: 320, alignment: .leading)
                .padding(8)
                .background(row.isHeader ? Color.secondary.opacity(0.12) : .clear)
                .overlay(alignment: .bottom) { Divider() }
            }
          }
        }
      }
    }
  }
}
