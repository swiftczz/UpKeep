import Foundation

struct ApplicationResidueOwner: Sendable {
  let applicationURL: URL
  let name: String
  var bundleIdentifiers: Set<String>
  var groupIdentifiers: Set<String>
  var updaterCacheDirName: String?
}

struct ApplicationResidueOwnershipInventory: Sendable {
  var owners: [ApplicationResidueOwner] = []
  var isComplete = false

  func matcher(
    identity: ApplicationResidueIdentity,
    applicationURL: URL,
    declaredGroups: Set<String>
  ) -> ApplicationResidueMatcher {
    let path = applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
    let own = owners.filter { $0.applicationURL.path == path }
    return ApplicationResidueMatcher(
      identity: identity,
      ownIdentifiers: own.reduce(into: Set([identity.bundleIdentifier])) {
        $0.formUnion($1.bundleIdentifiers)
      },
      groups: own.reduce(into: declaredGroups) { $0.formUnion($1.groupIdentifiers) },
      others: owners.filter { $0.applicationURL.path != path },
      isComplete: isComplete
    )
  }

  static func scan(
    applicationDirectories: [URL],
    fileManager: FileManager = .default,
    applicationGroups: @Sendable (URL) -> Set<String>? = ApplicationCodeSigning.applicationGroups(
      at:),
    updaterCacheDirName: @Sendable (URL) -> String? = { _ in nil }
  ) -> ApplicationResidueOwnershipInventory {
    var inventory = ApplicationResidueOwnershipInventory(isComplete: true)
    var seen = Set<String>()
    var applicationURLs: [URL] = []

    for directory in applicationDirectories where fileManager.fileExists(atPath: directory.path) {
      guard
        let enumerator = fileManager.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, _ in
            inventory.isComplete = false
            return true
          }
        )
      else {
        inventory.isComplete = false
        continue
      }
      for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
        enumerator.skipDescendants()
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard seen.insert(url.path).inserted else { continue }
        applicationURLs.append(url)
      }
    }
    let urls = applicationURLs
    let results = ResidueOwnerScanResults()
    let workerCount = min(4, urls.count)
    if workerCount > 0 {
      DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
        let workerFileManager = FileManager()
        for index in stride(from: worker, to: urls.count, by: workerCount) {
          results.append(
            scanOwner(
              at: urls[index], fileManager: workerFileManager,
              applicationGroups: applicationGroups, updaterCacheDirName: updaterCacheDirName
            ))
        }
      }
    }
    let scanned = results.snapshot
    inventory.owners = scanned.compactMap(\.owner).sorted {
      $0.applicationURL.path < $1.applicationURL.path
    }
    inventory.isComplete = inventory.isComplete && scanned.allSatisfy(\.isComplete)
    return inventory
  }

  private static func scanOwner(
    at url: URL,
    fileManager: FileManager,
    applicationGroups: (URL) -> Set<String>?,
    updaterCacheDirName: (URL) -> String?
  ) -> (owner: ApplicationResidueOwner?, isComplete: Bool) {
    var isComplete = true
    guard let bundle = bundleWithIdentifier(at: url), let identifier = bundle.bundleIdentifier
    else {
      return (nil, false)
    }
    var owner = ApplicationResidueOwner(
      applicationURL: url,
      name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
          ?? url.deletingPathExtension().lastPathComponent,
      bundleIdentifiers: [identifier],
      groupIdentifiers: [],
      updaterCacheDirName: updaterCacheDirName(bundle.bundleURL)
    )
    var pendingBundles = [bundle.bundleURL]
    var inspectedBundles = Set<String>()
    while let bundleURL = pendingBundles.popLast() {
      guard inspectedBundles.insert(bundleURL.path).inserted else { continue }
      if let groups = applicationGroups(bundleURL) {
        owner.groupIdentifiers.formUnion(groups)
      } else {
        isComplete = false
      }
      if let identifier = Bundle(url: bundleURL)?.bundleIdentifier {
        owner.bundleIdentifiers.insert(identifier)
      }
      // Inspect all embedded code bundles, including helpers nested inside frameworks.
      guard
        let children = fileManager.enumerator(
          at: bundleURL,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [],
          errorHandler: { _, _ in
            isComplete = false
            return true
          }
        )
      else {
        isComplete = false
        continue
      }
      for case let child as URL in children {
        guard
          ["app", "appex", "xpc", "systemextension"].contains(
            child.pathExtension.lowercased()
          )
        else { continue }
        children.skipDescendants()
        let resolved = child.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(url.path + "/") else {
          isComplete = false
          continue
        }
        pendingBundles.append(resolved)
      }
    }
    return (owner, isComplete)
  }

  private static func bundleWithIdentifier(at url: URL) -> Bundle? {
    if let bundle = Bundle(url: url), bundle.bundleIdentifier != nil { return bundle }
    let wrapped = url.appendingPathComponent("WrappedBundle").resolvingSymlinksInPath()
    if let bundle = Bundle(url: wrapped), bundle.bundleIdentifier != nil { return bundle }
    return nil
  }
}

struct ApplicationResidueMatcher: Sendable {
  let identity: ApplicationResidueIdentity
  let ownIdentifiers: Set<String>
  let groups: Set<String>
  let others: [ApplicationResidueOwner]
  let isComplete: Bool

  func match(leaf: String, location: ApplicationResidueLocation) -> ApplicationResidueMatchReason? {
    let isGroupLocation = location == .groupContainers || location == .applicationScripts
    let matchesOwnIdentifier = ownIdentifiers.contains {
      ApplicationResidueIdentity.matchesExactBundleIdentifier($0, leaf: leaf, location: location)
    }
    let candidate =
      matchesOwnIdentifier
      ? ApplicationResidueMatchReason.bundleIdentifier
      : identity.match(leaf: leaf, location: location)

    if isGroupLocation {
      let groupUsers = others.filter { $0.groupIdentifiers.contains(leaf) }
      if groups.contains(leaf) {
        if !groupUsers.isEmpty { return .sharedWith(names(of: groupUsers)) }
        return isComplete ? .declaredGroupContainer : .unverifiedGroupContainer
      }
      // A declared group owned only by another app is not this app's residue.
      if !groupUsers.isEmpty { return nil }
    }

    guard let candidate else { return nil }
    let otherUsers = others.filter { owner in
      owner.bundleIdentifiers.contains {
        ApplicationResidueIdentity.matchesExactBundleIdentifier($0, leaf: leaf, location: location)
      }
    }
    if !otherUsers.isEmpty {
      return matchesOwnIdentifier ? .sharedWith(names(of: otherUsers)) : nil
    }

    // A known separate app owns its more specific namespace, including helper/cache suffixes.
    if candidate == .possibleBundleVariant,
      others.contains(where: { owner in
        owner.bundleIdentifiers.contains { identifier in
          let identifier = identifier.lowercased()
          let bundle = identity.bundleIdentifier.lowercased()
          let leaf = leaf.lowercased()
          return (identifier.hasPrefix(bundle + ".") || identifier.hasPrefix(bundle + "-"))
            && (leaf == identifier || leaf.hasPrefix(identifier + ".")
              || leaf.hasPrefix(identifier + "-"))
        }
      })
    {
      return nil
    }

    if location == .groupContainers { return .undeclaredGroupContainer }
    if candidate == .declaredUpdaterCache {
      let cacheUsers = others.filter { $0.updaterCacheDirName == leaf }
      if !cacheUsers.isEmpty { return .sharedWith(names(of: cacheUsers)) }
    }
    return candidate
  }

  private func names(of owners: [ApplicationResidueOwner]) -> [String] {
    Set(owners.map(\.name)).sorted()
  }
}

private final class ResidueOwnerScanResults: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [(owner: ApplicationResidueOwner?, isComplete: Bool)] = []

  func append(_ result: (owner: ApplicationResidueOwner?, isComplete: Bool)) {
    lock.withLock { storage.append(result) }
  }

  var snapshot: [(owner: ApplicationResidueOwner?, isComplete: Bool)] {
    lock.withLock { storage }
  }
}
