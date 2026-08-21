# AppPulse

AppPulse 是一个面向 macOS 26 及以上系统的应用更新检查工具。它扫描本机应用，识别实际更新来源，并在原生 SwiftUI 双栏界面中展示当前版本、最新版本和发行说明。

应用源码不直接导入 AppKit：窗口与网页 URL 操作使用 SwiftUI，应用图标通过 Quick Look Thumbnailing 读取为 Core Graphics 图像；本地应用启动、本机扫描、网络和进程操作由 Foundation 完成。

## 当前能力

- 扫描 `/Applications` 和 `~/Applications`
- 读取应用图标、名称、Bundle ID、版本和构建号
- 对应用图标进行异步生成、请求合并和内存缓存，长列表滚动时不重复读取同一图标
- 按系统首选语言读取应用名称，并按应用包本地修改时间从新到旧排列
- 识别原生 Mac App Store receipt，以及安装在 Mac 上的 iPhone/iPad App Store 包
- 按本地应用平台分别查询 Mac 或 iPhone/iPad 商店版本，避免跨平台误配
- 应用列表中的 App Store 来源统一显示苹果 Logo；详情徽标附加 `macwindow`、`iphone`、`ipad` 小图标区分平台
- 识别 Homebrew Cask，并使用 Homebrew 的更新判断结果
- 识别 Sparkle Appcast，并解析版本、发布日期和发行说明
- 对其余未知应用读取 macOS 下载来源，并识别 Electron 明确声明的 GitHub Provider；可确认时标记为 GitHub
- 对无法安全查询的应用标记为“由应用自身管理”
- 按“可用更新”和“已安装的应用”分组
- 刷新时保持当前列表和选择稳定，扫描与检查结束后一次性提交最终分组，避免点击应用时列表跳动
- 支持在更新列表中右键忽略应用更新，并在已安装列表中取消忽略；忽略状态会跨启动保留
- 支持应用搜索、详情查看、检查更新和安全的更新入口
- Homebrew Cask 可由 AppPulse 执行更新；其他来源交回原管理工具

## 环境要求

- macOS 26.0+
- Xcode 26+
- Swift 6.2+
- Homebrew 为可选项；未安装时不启用 Homebrew 来源

## 使用 Swift Package Manager

工程由根目录的 `Package.swift` 管理，不依赖 `.xcodeproj`。

在 Xcode 中打开 `Package.swift`，选择 AppPulse executable scheme 后运行；也可以在项目目录执行：

```sh
swift run AppPulse
```

运行测试：

```sh
swift test
```

## 编译、运行与打包

项目提供了与 DeepListen 使用方式一致的脚本：

```sh
./script/build_and_run.sh
```

常用开发模式：

| 命令 | 用途 |
| --- | --- |
| `./script/build_and_run.sh` | Debug 编译、组装 `.app` 并启动 |
| `./script/build_and_run.sh --debug` | 使用 LLDB 启动应用 |
| `./script/build_and_run.sh --logs` | 启动应用并跟踪系统日志 |
| `./script/build_and_run.sh --verify` | 启动并确认应用进程正常存活 |

构建发布包：

```sh
APP_VERSION=0.1.0 ./script/build_and_run.sh --build-only universal --sign --dmg
APP_VERSION=0.1.0 ./script/build_and_run.sh --build-only arm64     --sign --dmg
APP_VERSION=0.1.0 ./script/build_and_run.sh --build-only x86_64    --sign --dmg
```

- `--build-only` 使用 Release 配置，并在 `dist/` 生成 `AppPulse.app`。
- `--sign` 默认使用 Ad-hoc 签名；设置 `SIGN_IDENTITY="Developer ID Application: …"` 可改用 Developer ID 和 Hardened Runtime。
- `--dmg` 生成 `AppPulse-<架构>-<版本>.dmg`，内含应用和指向 `/Applications` 的拖拽安装入口。
- `APP_VERSION` 默认取最近的 Git tag，没有 tag 时为 `0.1.0-dev`。
- `APP_BUILD` 默认取当前仓库提交数，也可以通过环境变量明确指定。
- 如果添加 `Resources/AppIcon.icns`，脚本会自动将其写入应用包。

## 目录结构

```text
AppPulse/
├── Package.swift
├── script/
│   └── build_and_run.sh
├── AppPulse/
│   ├── Models/
│   ├── Services/
│   ├── Store/
│   ├── Views/
│   └── Resources/
├── AppPulseTests/
└── 需求文档.md
```

## 首版边界

- App Store 应用只跳转至官方商店，不由 AppPulse 替换安装。
- Sparkle 应用使用其官方 Feed 展示信息，更新仍由应用自己的更新器完成。
- GitHub 兜底识别只标注可确认的来源，不等同于 AppPulse 已能自动下载或安装 GitHub Releases。
- Homebrew 通常不提供发行说明，因此详情可能只有版本与主页。
- 动态或需要鉴权的更新源不会被强行解析。
- 脚本可以生成 `.app` 和 DMG；公开分发前仍需配置 Developer ID 签名、公证和正式应用图标。
