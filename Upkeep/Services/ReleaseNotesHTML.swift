import Foundation

enum ReleaseNotesHTML {
  static func text(_ html: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
    // Foundation's HTML tidy predates HTML5 and otherwise discards semantic containers.
    var compatibleHTML = html
    for tag in ["article", "main", "section", "header", "footer", "nav", "aside", "template"] {
      compatibleHTML = compatibleHTML.replacingOccurrences(
        of: "(?i)<\(tag)\\b", with: "<div data-upkeep-element=\"\(tag)\"", options: .regularExpression)
        .replacingOccurrences(of: "(?i)</\(tag)\\s*>", with: "</div>", options: .regularExpression)
    }
    guard let document = try? XMLDocument(xmlString: compatibleHTML,
      options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }
    func first(_ query: String) -> XMLNode? { (try? document.nodes(forXPath: query))?.first }
    let root = first("//*[@data-upkeep-element='article'][contains(concat(' ', normalize-space(@class), ' '), ' release-paper ')]")
      ?? first("//*[@data-upkeep-element='article'][.//h1]") ?? first("//*[@data-upkeep-element='main']") ?? first("//body") ?? document
    let chinese = preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    let preferredClass = chinese ? "l-zh" : "l-en"
    let alternateClass = chinese ? "l-en" : "l-zh"
    let preferredNodes = try? root.nodes(forXPath:
      ".//*[contains(concat(' ', normalize-space(@class), ' '), ' \(preferredClass) ')]")
    let hasPreferred = !(preferredNodes?.isEmpty ?? true)
    let omittedTags: Set<String> = ["head", "script", "style", "noscript", "nav", "aside",
      "footer", "select", "button", "svg", "template"]
    let omittedClasses: Set<String> = ["release-surfaces", "release-builds", "release-target-summary",
      "release-item-targets", "release-refs", "release-guide__arrow", "release-download",
      "release-guides", "release-highlight__index", "release-highlight__kind", "release-notice__icon"]
    func render(_ node: XMLNode) -> String {
      if node.kind == .text {
        return (node.stringValue ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      }
      guard node.kind != .comment else { return "" }
      let element = node as? XMLElement
      let tag = element?.attribute(forName: "data-upkeep-element")?.stringValue ?? node.name?.lowercased() ?? ""
      let classes = Set((element?.attribute(forName: "class")?.stringValue ?? "").split(separator: " ").map(String.init))
      if omittedTags.contains(tag) || !classes.isDisjoint(with: omittedClasses)
        || (hasPreferred && classes.contains(alternateClass))
        || element?.attribute(forName: "hidden") != nil
        || element?.attribute(forName: "aria-hidden")?.stringValue == "true" { return "" }
      if tag == "span", let parent = node.parent as? XMLElement,
        (parent.attribute(forName: "class")?.stringValue ?? "").split(separator: " ").contains("release-section__head") {
        return ""
      }
      if tag == "br" { return "\n" }
      let content = (node.children ?? []).map(render).joined()
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return "" }
      if tag == "li" { return "\n• \(trimmed)\n" }
      if ["h1", "h2", "h3", "h4", "h5", "h6", "p", "section", "article", "ul", "ol", "header"].contains(tag) {
        return "\n\n\(trimmed)\n\n"
      }
      if ["div", "tr"].contains(tag) { return "\n\(trimmed)\n" }
      if tag == "td" || tag == "th" { return "\(trimmed)  " }
      return content
    }
    let lines = render(root).components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return lines.nonBlankValue
  }
}
