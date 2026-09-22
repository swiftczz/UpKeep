import Foundation

/// Metadata from the selected app only. No inventory, cache or startup work.
struct ApplicationResidueTarget: Sendable {
  let bundleURL: URL
  var embeddedIdentifiers: Set<String> = []
  var groups: Set<String> = []

  static func read(
    at applicationURL: URL,
    fileManager: FileManager,
    applicationGroups: (URL) -> Set<String>?
  ) -> Self {
    let root = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    let wrapped = root.appendingPathComponent("WrappedBundle").resolvingSymlinksInPath()
    let bundleURL = Bundle(url: root)?.bundleIdentifier != nil ? root
      : (Bundle(url: wrapped)?.bundleIdentifier != nil ? wrapped : root)
    var target = Self(bundleURL: bundleURL)
    var pending = [bundleURL]
    var visited = Set<String>()

    while let bundle = pending.popLast() {
      guard !Task.isCancelled else { break }
      let resolved = bundle.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.path == bundleURL.path || resolved.path.hasPrefix(bundleURL.path + "/"),
        visited.insert(resolved.path).inserted
      else { continue }
      if resolved.pathExtension != "framework" {
        target.groups.formUnion(applicationGroups(resolved) ?? [])
        if resolved != bundleURL, let id = Bundle(url: resolved)?.bundleIdentifier {
          target.embeddedIdentifiers.insert(id)
        }
      }

      // Only known code locations, never Resources, user data or arbitrary trees.
      var bases = [resolved, resolved.appendingPathComponent("Contents")]
      if resolved.pathExtension == "framework" {
        let versions = resolved.appendingPathComponent("Versions")
        bases += (try? fileManager.contentsOfDirectory(
          at: versions, includingPropertiesForKeys: nil)) ?? []
      }
      for base in bases {
        for path in ["PlugIns", "XPCServices", "Helpers", "Frameworks",
          "Library/LoginItems", "Library/SystemExtensions"] {
          guard !Task.isCancelled else { return target }
          let directory = base.appendingPathComponent(path).resolvingSymlinksInPath()
          guard directory.path.hasPrefix(bundleURL.path + "/") else { continue }
          let children = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
          pending += children.filter {
            ["app", "appex", "xpc", "systemextension", "framework"].contains($0.pathExtension)
          }
        }
      }
    }
    return target
  }
}

struct ApplicationResidueMatcher: Sendable {
  let identity: ApplicationResidueIdentity
  let target: ApplicationResidueTarget
  let otherApplications: [AppRecord]

  func match(leaf: String, location: ApplicationResidueLocation) -> ApplicationResidueMatchReason? {
    if (location == .groupContainers || location == .applicationScripts),
      target.groups.contains(leaf) { return .unverifiedGroupContainer }

    let embedded = target.embeddedIdentifiers.contains {
      ApplicationResidueIdentity.matchesExactBundleIdentifier($0, leaf: leaf, location: location)
    }
    guard let candidate = identity.match(leaf: leaf, location: location)
      ?? (embedded ? .embeddedBundle : nil) else { return nil }

    // Existing library records can identify duplicate installs without filesystem work.
    let others = otherApplications.filter {
      ApplicationResidueIdentity.matchesExactBundleIdentifier(
        $0.bundleIdentifier, leaf: leaf, location: location)
    }
    if !others.isEmpty {
      return candidate == .bundleIdentifier
        ? .sharedWith(Array(Set(others.map(\.name))).sorted()) : nil
    }
    if candidate == .possibleBundleVariant, otherApplications.contains(where: { app in
      let identifier = app.bundleIdentifier.lowercased()
      let bundle = identity.bundleIdentifier.lowercased()
      let name = leaf.lowercased()
      return (identifier.hasPrefix(bundle + ".") || identifier.hasPrefix(bundle + "-"))
        && (name == identifier || name.hasPrefix(identifier + ".") || name.hasPrefix(identifier + "-"))
    }) { return nil }
    if location == .groupContainers { return .undeclaredGroupContainer }
    // A bundled SDK helper can be shared by unrelated apps (e.g. Sparkle).
    if embedded, candidate != .bundleIdentifier { return .embeddedBundle }
    return candidate
  }
}
