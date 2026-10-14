import SwiftUI

struct GitHubConnectionNotice: View {
  let message: String
  @Environment(GitHubAccount.self) private var githubAccount

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Label(isRateLimited ? "GitHub 请求额度暂时用完" : "GitHub 授权已失效", systemImage: "exclamationmark.circle")
          .font(.callout.weight(.medium))
        Spacer()
        SettingsLink {
          Text(githubAccount.isConnected ? "打开设置" : "连接 GitHub")
        }
        .buttonStyle(.glass)
      }

      Text(isRateLimited && githubAccount.isConnected
        ? "请稍后再检查更新。"
        : isRateLimited
          ? "连接 GitHub 可提高检查更新的请求额度。"
          : "请在设置中重新连接 GitHub，再检查更新。")
        .font(.callout)
        .foregroundStyle(.secondary)

      DisclosureGroup("查看详情") {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .padding(.top, 6)
      }
      .font(.caption)
    }
  }

  private var isRateLimited: Bool { message.contains("限流") }

  static func recognizes(_ message: String) -> Bool {
    (message.contains("GitHub") && message.contains("限流"))
      || message == GitHubAuthenticationError.invalidToken.localizedDescription
  }
}
