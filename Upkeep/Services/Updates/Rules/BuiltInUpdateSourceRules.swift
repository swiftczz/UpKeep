import Foundation

extension UpdateSourceRuleSet {
    /// Rules shipped with Upkeep, written in the same format as user rule files.
    static let builtIn: UpdateSourceRuleSet = {
        do {
            let rules = try JSONDecoder().decode(
                [UpdateSourceRule].self, from: Data(builtInRulesJSON.utf8))
            return UpdateSourceRuleSet(rules: rules)
        } catch {
            assertionFailure("Built-in update source rules are invalid: \(error)")
            return .empty
        }
    }()

    /// - `storyteller-craft`: Storyteller's Craft apps publish to `storytold/<slug>`
    ///   without an embedded endpoint. Only a fallback: anything the bundle declares
    ///   wins, and the provider must still read a valid release.
    /// - `aicoin`: AiCoin's `app-update.yml` says `provider: custom`; the app sets
    ///   electron-builder's generic feed (`GENERIC_SERVER_URL`, channel `latest`)
    ///   in its bundled JavaScript instead.
    static let builtInRulesJSON = #"""
        [
          {
            "id": "aicoin",
            "name": "AiCoin",
            "kind": "updaterFeed",
            "format": "electronBuilder",
            "match": { "bundleIdentifier": "com.aicoin.desktop" },
            "feed": "https://pc-package-1326437257.cos.ap-hongkong.myqcloud.com/download/latest-mac.yml",
            "homepage": "https://www.aicoin.com/download"
          },
          {
            "id": "storyteller-craft",
            "name": "Storyteller Craft",
            "kind": "githubReleases",
            "precedence": "fallback",
            "match": {
              "bundleIdentifierPattern": "ai\\.storyteller\\.(?<slug>[a-z0-9][a-z0-9-]{0,94}craft)"
            },
            "repository": "storytold/{slug}",
            "assetNamePrefix": "{slug}-"
          }
        ]
        """#
}
