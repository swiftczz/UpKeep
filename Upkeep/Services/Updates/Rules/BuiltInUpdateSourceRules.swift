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
    /// - `fluxdown`: FluxDown's release API, which its Rust binary only builds from
    ///   separate origin and path strings.
    /// - `workbuddy`, `workbuddy-ai`: WorkBuddy's v2 update API answers 204 when the
    ///   installed version is current, and otherwise describes one package.
    /// - `zcode`: ZCode's app-update.yml is a localhost placeholder; the app builds
    ///   its electron-builder manifest URL in code.
    /// - `clash-verge-rev`: Clash Verge Rev publishes its Tauri manifest as
    ///   `update-proxy.json` on a fixed `updater` release.
    /// - `reasonix`: Reasonix's Electron shell leaves updates to a native service
    ///   in its resources, which embeds this manifest.
    ///   Its manifest links notes to a bilingual web page; the GitHub release for the
    ///   same version carries them as Markdown.
    /// - `reasonix-studio`: Reasonix Studio publishes a `versions.json` catalog; the
    ///   Tauri provider follows it to the newest stable release's manifest.
    /// - `lorca`: egoist/lorca also releases the CLI and mobile apps; only
    ///   `desktop-v` tags are the Mac app.
    /// - `gigamoney`: GigaMoney's app-update.yml is a localhost placeholder; its
    ///   bundled tenant feed map names the production feed.
    static let builtInRulesJSON = #"""
        [
          {
            "id": "reasonix",
            "name": "Reasonix",
            "kind": "updaterFeed",
            "format": "tauri",
            "match": { "bundleIdentifier": "com.wails.reasonix-desktop" },
            "feed": "https://dl.reasonix.io/latest/latest.json",
            "releaseNotes": "https://github.com/esengine/DeepSeek-Reasonix/releases/tag/desktop-v{latestVersion}"
          },
          {
            "id": "reasonix-studio",
            "name": "Reasonix Studio",
            "kind": "updaterFeed",
            "format": "tauri",
            "match": { "bundleIdentifier": "io.reasonix.studio" },
            "feed": "https://dl.reasonix.io/studio/versions.json"
          },
          {
            "id": "lorca",
            "name": "Lorca",
            "kind": "githubReleases",
            "match": { "bundleIdentifier": "app.lorca" },
            "repository": "egoist/lorca",
            "tagPrefix": "desktop-v"
          },
          {
            "id": "clash-verge-rev",
            "name": "Clash Verge Rev",
            "kind": "updaterFeed",
            "format": "tauri",
            "match": { "bundleIdentifier": "io.github.clash-verge-rev.clash-verge-rev" },
            "feed": "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/updater/update-proxy.json",
            "homepage": "https://github.com/clash-verge-rev/clash-verge-rev"
          },
          {
            "id": "workbuddy",
            "name": "WorkBuddy",
            "kind": "jsonFeed",
            "match": { "bundleIdentifier": "com.tencent.workbuddy.mac" },
            "feed": "https://www.workbuddy.cn/v2/update?platform=workbuddy-darwin-{arch}&version={version}",
            "homepage": "https://copilot.tencent.com/cli",
            "fields": {
              "version": "version",
              "date": "timestamp",
              "assetURL": "url",
              "assetSHA256": "sha256hash"
            }
          },
          {
            "id": "workbuddy-ai",
            "name": "WorkBuddy AI",
            "kind": "jsonFeed",
            "match": { "bundleIdentifier": "com.workbuddy.workbuddy-ai" },
            "feed": "https://www.workbuddy.ai/v2/update?platform=workbuddy-darwin-{arch}&version={version}",
            "homepage": "https://www.workbuddy.ai/",
            "fields": {
              "version": "version",
              "date": "timestamp",
              "assetURL": "url",
              "assetSHA256": "sha256hash"
            }
          },
          {
            "id": "zcode",
            "name": "ZCode",
            "kind": "updaterFeed",
            "format": "electronBuilder",
            "match": { "bundleIdentifier": "dev.zcode.app" },
            "feed": "https://zcode.z.ai/api/v1/releases/electron/manifest?platform=darwin-{arch}&channel=1",
            "homepage": "https://zcode.z.ai"
          },
          {
            "id": "gigamoney",
            "name": "GigaMoney",
            "kind": "updaterFeed",
            "format": "electronBuilder",
            "match": { "bundleIdentifier": "lb.whale.winner.desktop" },
            "feed": "https://download.longbridgewhale.com/winner-desktop/prod/latest-mac.yml",
            "homepage": "https://longbridgeapp.com"
          },
          {
            "id": "fluxdown",
            "name": "FluxDown",
            "kind": "jsonFeed",
            "match": { "bundleIdentifier": "com.fluxdown.app" },
            "feed": "https://fluxdown.com/api/release?channel=stable",
            "homepage": "https://fluxdown.com/changelog",
            "fields": {
              "version": "version",
              "date": "published_at",
              "assets": "assets",
              "assetURL": ["download_url", "github_download_url"],
              "assetName": "name",
              "assetSize": "size"
            }
          },
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
