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

    /// Storyteller's Craft apps publish to `storytold/<slug>` without an embedded
    /// endpoint. They are only a fallback: anything the bundle declares wins, and
    /// the provider must still read a valid release before offering an update.
    static let builtInRulesJSON = #"""
        [
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
