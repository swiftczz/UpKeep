# Upkeep

**在一个窗口里，检查、更新和卸载 Mac 应用。**

Upkeep 会扫描本机已安装的 `.app`，识别各应用的更新来源，集中展示新版本和更新说明。支持直接安装的更新可以单独执行，也可以批量安装；不再需要的应用则可以连同选中的关联文件一起移到废纸篓。

> 系统要求：**macOS 26 或更高版本**，**Apple Silicon（M 系列芯片）**。目前不提供 Intel 版本。

## 下载与安装

1. 前往[最新版本页面](https://github.com/swiftczz/UpKeep/releases/latest)，下载附件中的 `Upkeep-<版本号>.dmg`。
2. 打开 DMG，将 **Upkeep** 拖入 **Applications（应用程序）** 文件夹。
3. 启动 Upkeep，查看扫描结果；点击工具栏的“检查更新”或按 `⌘R`，重新扫描并检查版本。

历史版本与各版本的更新说明可在 [Releases](https://github.com/swiftczz/UpKeep/releases) 查看。

## 主要功能

- **集中检查更新**：自动识别应用使用的更新来源，查看当前版本、最新版本、发布日期和更新包大小。
- **单独或批量更新**：安装可自动更新的应用；需要退出正在运行的应用时，会先提示确认。
- **直接阅读更新说明**：在详情页查看 Markdown 或网页正文，也可以打开完整说明。
- **搜索与忽略更新**：按应用名、Bundle ID 或更新来源搜索，将暂时不想更新的应用放入忽略列表。
- **卸载与关联文件清理**：查看并选择要移除的文件，将应用和选中的关联文件移到废纸篓。

## 支持的更新来源

| 来源 | 处理方式 |
| --- | --- |
| Mac App Store | 支持条件满足时下载安装；需要通过商店处理的应用会跳转到 App Store。 |
| Homebrew | 识别由 Homebrew Cask 管理的应用，并通过 Homebrew 更新。 |
| Sparkle、electron-updater、Tauri updater | 读取应用的更新清单，获取版本、更新说明和安装包。 |
| VS Code updater、JSON Release | 支持识别到的对应更新协议与清单格式。 |
| GitHub Releases | 读取对应 Release 的版本、说明和兼容的安装包。 |
| 应用自行更新 | 提供打开应用的入口，使用应用自身的更新功能。 |

能否直接安装取决于更新源是否提供兼容的安装包。仅提供更新页面的条目会显示“查看更新”，没有可安装更新的条目可以直接打开应用。

通过 GitHub 发布页链接读取更新说明时，统一优先读取 API 正文，必要时回退到发布网页的正文区域，过滤仓库导航、Star、标签选择和附件列表。

## 日常使用

左侧列表分为“可用更新”“已安装的应用”和“已忽略的更新”三组。搜索框支持输入 `Sparkle`、`Homebrew`、`GitHub` 等来源名称。

选中应用后，右侧展示版本和更新说明。主按钮右侧的菜单提供“在 Finder 中显示”和“卸载”等操作；在侧栏右键点击应用，可以忽略更新或取消忽略。

| 操作 | 用途 |
| --- | --- |
| 检查更新 / `⌘R` | 重新扫描本机应用并检查更新。 |
| 更新 | 下载并安装当前应用可自动安装的更新。 |
| 更新全部 | 更新所有未被忽略且可自动更新的应用。 |
| 查看完整说明 | 在浏览器中打开更新说明来源页面。 |

## 从源码运行

需要 **Xcode 26 或更高版本**及 **Swift 6.2 或更高版本**。项目使用 SwiftUI 和 Swift Package Manager，没有第三方 Swift 包依赖。

```sh
git clone https://github.com/swiftczz/UpKeep.git
cd UpKeep

# 编译 Debug 版本，组装为 .app 并启动
./scripts/build_and_run.sh

# 运行测试
swift test
```

也可以用 Xcode 打开根目录的 `Package.swift`，选择 Upkeep scheme 运行。完整应用包及安装助手由构建脚本组装；`swift run Upkeep` 只运行裸二进制。

其他调试方式：

```sh
./scripts/build_and_run.sh --debug   # 使用调试器启动
./scripts/build_and_run.sh --logs    # 启动并跟踪系统日志
./scripts/build_and_run.sh --verify  # 启动后检查进程状态
```

## 构建发布包

```sh
./scripts/build_and_run.sh --build-only --sign --dmg
```

构建产物：

- `dist/Upkeep.app`：包含主程序与安装助手的应用包。
- `dist/Upkeep-<版本号>.dmg`：包含 Applications 快捷方式的安装镜像。

主程序与安装助手均构建为 arm64。版本号优先读取 `APP_VERSION`，未设置时使用最近的 Git tag；没有 tag 时为 `0.1.0-dev`。构建号优先读取 `APP_BUILD`，否则使用当前 Git 提交数。

`--sign` 优先使用 `SIGN_IDENTITY` 指定的证书，其次使用 `DEVELOPMENT_SIGN_IDENTITY` 或本机 Apple Development 证书；没有可用证书时使用 Ad-hoc 签名。面向外部分发的 Developer ID 签名与公证需要另行配置。

推送 `v*` 标签后，GitHub Actions 会构建 DMG、生成更新记录并上传到对应 Release。手动运行工作流时，DMG 作为工作流附件提供。

## 项目结构

```text
Package.swift                       Swift Package Manager 配置
Resources/                          应用图标
scripts/                            构建、打包、更新记录与图标生成脚本
Upkeep/
  Models/                           应用、更新来源与状态模型
  Services/                         扫描、更新源、说明解析、安装与卸载
  Store/                            应用列表状态与本地缓存
  Views/                            侧栏、详情与卸载界面
UpkeepPrivilegedHelper/             App Store pkg 安装助手
UpkeepPrivilegedHelperProtocol/     主程序与助手共用的 XPC 协议
UpkeepTests/                        主程序测试
UpkeepPrivilegedHelperTests/        安装助手测试
```

### 修改图标

调整 `scripts/make_app_icon.py` 中的颜色和几何参数后运行：

```sh
python3 scripts/make_app_icon.py Resources
```

脚本需要 Pillow，生成的图标位于 `Resources/`。使用不透明的 1024 × 1024 方图，圆角和阴影交由系统处理。

## 反馈问题

请在 [Issues](https://github.com/swiftczz/UpKeep/issues) 中反馈。更新识别或安装问题请附上 macOS 版本、应用名称、当前版本、更新来源以及错误信息，便于复现。
