import Foundation

extension AppRecord {
  struct SearchQuery: Sendable {
    let text: String
    let channel: UpdateChannel?
    let isMechanismQuery: Bool

    init(_ searchText: String) {
      let normalized = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      text = normalized
      channel = UpdateChannel.allCases.first { channel in
        channel.searchTerms.contains { UpdateMechanism.searchTerm($0, matches: normalized) }
      }
      isMechanismQuery =
        !text.isEmpty && (channel != nil || UpdateMechanism.isMechanismSearchQuery(text))
    }
  }

  func matchesSearch(_ searchText: String) -> Bool {
    matchesSearch(SearchQuery(searchText))
  }

  func matchesSearch(_ query: SearchQuery) -> Bool {
    guard !query.text.isEmpty else { return true }

    // Channel names filter the same channel shown in the list and detail.
    if let channel = query.channel {
      return updateConfiguration.channel == channel
    }
    if query.isMechanismQuery {
      return matchesMechanismSearch(query.text)
    }

    return name.localizedCaseInsensitiveContains(query.text)
      || bundleIdentifier.localizedCaseInsensitiveContains(query.text)
      || channelTitle.localizedCaseInsensitiveContains(query.text)
  }

  private func matchesMechanismSearch(_ query: String) -> Bool {
    let primaryTerms: [String]
    if updateConfiguration.mechanism == .appStore {
      primaryTerms =
        [updateConfiguration.mechanism.title, channelTitle]
        + [appStorePlatform?.title].compactMap { $0 }
    } else {
      primaryTerms = updateConfiguration.mechanism.searchTerms
    }
    return primaryTerms.contains { UpdateMechanism.searchTerm($0, matches: query) }
  }

}
