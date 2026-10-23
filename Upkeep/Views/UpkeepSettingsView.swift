import SwiftUI

struct UpkeepSettingsView: View {
    @Environment(GitHubAccount.self) private var githubAccount
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connectionSheet: GitHubConnectionMethod?
    @State private var errorMessage: String?
    @AppStorage(UpdateAllConcurrency.defaultsKey)
    private var concurrentUpdates = UpdateAllConcurrency.defaultLimit

    var body: some View {
        Form {
            Section {
                LabeledContent("同时更新的应用数") {
                    HStack(spacing: 4) {
                        TextField("同时更新的应用数", value: $concurrentUpdates, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                            .accessibilityIdentifier("settings.concurrentUpdates")
                        Stepper(
                            "同时更新的应用数", value: $concurrentUpdates,
                            in: UpdateAllConcurrency.range
                        )
                        .labelsHidden()
                    }
                }
                // Typed values outside the range snap back to the nearest allowed one.
                .onChange(of: concurrentUpdates) { _, value in
                    let range = UpdateAllConcurrency.range
                    let clamped = min(max(value, range.lowerBound), range.upperBound)
                    if clamped != value { concurrentUpdates = clamped }
                }
            } header: {
                Text("更新")
            } footer: {
                Text("用于“更新全部”。Homebrew 应用和需要管理员权限的安装包仍会逐个安装。")
            }

            Section {
                HStack(spacing: 14) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub").font(.headline)
                        Text(connectionDescription)
                            .font(.callout)
                            .foregroundStyle(
                                githubAccount.isConnected
                                    ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }

                    Spacer()

                    if githubAccount.isConnected {
                        Button("断开连接") { disconnect() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("github.disconnect")
                    } else {
                        Button(githubAccount.requiresReconnection ? "重新连接" : "连接 GitHub") {
                            connectionSheet =
                                githubAccount.canUseBrowserAuthorization ? .browser : .token
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("github.connect")
                    }
                }
                .padding(.vertical, 4)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: connectionDescription)

                Text(
                    githubAccount.isConnected
                        ? "检查 GitHub 应用更新时，将使用此账号的请求额度。"
                        : "连接后可提高请求额度，减少检查更新时遇到的限制。"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if !githubAccount.isConnected && githubAccount.canUseBrowserAuthorization {
                    Button("使用访问令牌连接…") { connectionSheet = .token }
                        .buttonStyle(.link)
                }

                if let message = errorMessage ?? githubAccount.storageError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } header: {
                Text("更新来源")
            } footer: {
                Text("连接是可选的。Upkeep 仅查询应用的发布信息，连接凭据保存在此 Mac 的钥匙串中。")
            }

            UpdateSourceRulesSection()
        }
        .formStyle(.grouped)
        // Grow with the content, such as an error message, instead of scrolling a fixed box.
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .navigationTitle("设置")
        .sheet(item: $connectionSheet) { method in
            GitHubConnectionSheet(method: method)
                .environment(githubAccount)
        }
    }

    private var connectionDescription: String {
        if githubAccount.requiresReconnection { return "授权已失效，请重新连接" }
        if let login = githubAccount.login { return "已连接 · @\(login)" }
        return "尚未连接"
    }

    private func disconnect() {
        do {
            try githubAccount.disconnect()
            errorMessage = nil
        } catch {
            errorMessage = GitHubAuthenticationError.presentable(error)
        }
    }
}

/// Where users add JSON rule files, and why a rule was rejected.
private struct UpdateSourceRulesSection: View {
    @State private var rules: UpdateSourceRuleSet?
    private let store = UpdateSourceRuleStore.shared

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义更新规则").font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Button("重新载入", action: reload)
                    .buttonStyle(.glass)
                Button("打开文件夹", action: openDirectory)
                    .buttonStyle(.glass)
            }
            .padding(.vertical, 4)

            ForEach(rules?.issues ?? [], id: \.self) { issue in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.source).font(.callout.weight(.medium))
                        Text(issue.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("把 JSON 规则文件放进此文件夹，下次检查更新时生效。规则只决定从哪里读取更新信息，不会放宽安装包的签名校验。")
        }
        .task { reload() }
    }

    private var summary: String {
        guard let rules else { return "正在读取…" }
        let count = rules.rules.count
        if count == 0 { return rules.issues.isEmpty ? "尚未添加规则" : "没有可用的规则" }
        return "已载入 \(count) 条规则"
    }

    private func reload() {
        rules = store.userRules()
    }

    private func openDirectory() {
        let directory = store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}

enum GitHubConnectionMethod: String, Identifiable {
    case browser
    case token
    var id: String { rawValue }
}

private struct GitHubConnectionSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let method: GitHubConnectionMethod
    @Environment(GitHubAccount.self) private var githubAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var authorization: GitHubDeviceAuthorization?
    @State private var token = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var didOpenBrowser = false
    @State private var attemptID = UUID()
    @State private var tokenTask: Task<Void, Never>?
    @FocusState private var tokenIsFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text("连接 GitHub")
                .font(.title2.weight(.semibold))

            if method == .browser {
                browserContent
            } else {
                tokenContent
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("github.connection.error")
            }

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("取消", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.glass)

                    if method == .token {
                        Button {
                            connectToken()
                        } label: {
                            HStack(spacing: 8) {
                                if isWorking { ProgressView().controlSize(.small) }
                                Text(isWorking ? "正在连接…" : "连接")
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || token.nonBlankValue == nil)
                    } else if let authorization, errorMessage == nil {
                        Button(didOpenBrowser ? "重新打开 GitHub" : "复制验证码并打开 GitHub") {
                            copyCodeAndOpen(authorization)
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                    } else if errorMessage != nil {
                        Button("重试") { attemptID = UUID() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }

            Text("仅用于查询应用的发布信息")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: sheetState)
        .task(id: attemptID) {
            if method == .browser { await authorizeInBrowser() } else { tokenIsFocused = true }
        }
        .onDisappear {
            tokenTask?.cancel()
            tokenTask = nil
            token = ""
        }
        .interactiveDismissDisabled(isWorking && method == .token)
    }

    @ViewBuilder
    private var browserContent: some View {
        if let authorization {
            Text(didOpenBrowser ? "等待你在浏览器中完成授权…" : "在 GitHub 授权页面输入下方验证码。")
                .foregroundStyle(.secondary)

            Text(authorization.userCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
                .accessibilityLabel("GitHub 验证码 \(authorization.userCode)")

            // The system renders the countdown as m:ss without rebuilding this view every second.
            Text(
                "验证码有效期：\(Text(timerInterval: Date.now...max(Date.now, authorization.expiresAt), countsDown: true))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("等待 GitHub 授权")
            }
        } else if isWorking {
            ProgressView("正在获取验证码…")
        }
    }

    private var tokenContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用 GitHub 访问令牌连接。令牌仅保存在此 Mac 的钥匙串中。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("GitHub 访问令牌", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($tokenIsFocused)
                .disabled(isWorking)
                .accessibilityIdentifier("github.token")

            Link(
                "在 GitHub 创建访问令牌",
                destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            Text("读取公开应用更新不需要增加仓库写入权限，请保留默认的公开信息读取权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !githubAccount.canUseBrowserAuthorization {
                Text("此版本尚未启用浏览器授权，可先使用访问令牌连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sheetState: [String?] {
        [authorization?.userCode, errorMessage, String(isWorking), String(didOpenBrowser)]
    }

    private func authorizeInBrowser() async {
        isWorking = true
        errorMessage = nil
        authorization = nil
        didOpenBrowser = false
        defer { isWorking = false }
        do {
            let challenge = try await githubAccount.client.requestDeviceAuthorization()
            try Task.checkCancellation()
            authorization = challenge
            let token = try await githubAccount.client.waitForAuthorization(challenge)
            try await githubAccount.connect(with: token)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = GitHubAuthenticationError.presentable(error)
        }
    }

    private func connectToken() {
        guard !isWorking, let value = token.nonBlankValue else { return }
        isWorking = true
        errorMessage = nil
        tokenTask = Task {
            defer {
                isWorking = false
                tokenTask = nil
            }
            do {
                try await githubAccount.connect(
                    with: GitHubAccessToken(value: value, expiresAt: nil))
                token = ""
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = GitHubAuthenticationError.presentable(error)
            }
        }
    }

    private func copyCodeAndOpen(_ authorization: GitHubDeviceAuthorization) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.userCode, forType: .string)
        openURL(authorization.verificationURL) { accepted in
            if accepted {
                didOpenBrowser = true
            } else {
                errorMessage = "无法打开浏览器，请前往 github.com/login/device 输入验证码。"
            }
        }
    }
}

#Preview("未连接") {
    UpkeepSettingsView().environment(GitHubAccount.preview())
}

#Preview("已连接") {
    UpkeepSettingsView().environment(GitHubAccount.preview(login: "octocat"))
}

#Preview("授权失效") {
    UpkeepSettingsView().environment(GitHubAccount.preview(login: "octocat", expired: true))
}
