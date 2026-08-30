# AppMint

AppMint 是一个面向 macOS 26 及以上系统的应用更新检查工具。它扫描本机应用，识别实际更新来源，并在原生 SwiftUI 双栏界面中展示当前版本、最新版本和发行说明。

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
- 识别 Electron-builder（`app-update.yml` 的 github / generic HTTPS 源）并检查 `latest-mac.yml`
- 识别 Tauri updater（`latest.json` / `update-proxy.json`）并检查版本、发行说明和安装包
- 识别应用自身明确引用的 GitHub Releases 稳定版接口，并检查版本、发行说明和当前 Mac 架构安装包
- 对无法安全查询的应用标记为“由应用自身管理”
- 按“可用更新”和“已安装的应用”分组
- 刷新时保持当前列表和选择稳定，扫描与检查结束后一次性提交最终分组，避免点击应用时列表跳动
- 支持在更新列表中右键忽略应用更新，并在已安装列表中取消忽略；忽略状态会跨启动保留
- 支持应用搜索、详情查看、检查更新和安全的更新入口
- 原生 Mac App Store 应用可复用 App Store 当前登录账号，由 AppMint 直接下载并安装更新
- Homebrew Cask 可由 AppMint 执行更新
- 带安全下载项的 Sparkle Appcast 可由 AppMint 校验 Ed25519 签名、开发者身份并安装
- Electron-builder、Tauri updater 与 GitHub Releases 可由 AppMint 下载 HTTPS 安装包并替换本地应用；提供校验值时会先验证
- 其他来源交回原管理工具

## 环境要求

- macOS 26.0+
- Xcode 26+
- Swift 6.2+
- Homebrew 为可选项；未安装时不启用 Homebrew 来源
- 不需要安装 `mas`；App Store 更新逻辑已经集成到 AppMint
- Sparkle 更新由 AppMint 直接解析和安装，不嵌入 Sparkle.framework

> App Store 直接更新使用 macOS 私有的 CommerceKit 与 StoreFoundation 框架，适合本地或
> Developer ID 分发，不能用于提交 Mac App Store。相关移植代码遵循 mas-cli/mas 的 MIT
> 许可，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 使用 Swift Package Manager

工程由根目录的 `Package.swift` 管理，不依赖 `.xcodeproj`。

在 Xcode 中打开 `Package.swift`，选择 AppMint executable scheme 后运行；也可以在项目目录执行：

```sh
swift run AppMint
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

- `--build-only` 使用 Release 配置，并在 `dist/` 生成 `AppMint.app`。
- `--sign` 默认使用 Ad-hoc 签名；设置 `SIGN_IDENTITY="Developer ID Application: …"` 可改用 Developer ID 和 Hardened Runtime。
- `--dmg` 生成 `AppMint-<架构>-<版本>.dmg`，内含应用和指向 `/Applications` 的拖拽安装入口。
- `APP_VERSION` 默认取最近的 Git tag，没有 tag 时为 `0.1.0-dev`。
- `APP_BUILD` 默认取当前仓库提交数，也可以通过环境变量明确指定。
- 如果添加 `Resources/AppIcon.icns`，脚本会自动将其写入应用包。

## 应用图标

图标是红底上的环形更新箭头，扁平化处理，底色上下只差一档明度。

`Resources/AppIcon.png` 与 `AppIcon.icns` 不是图片素材，而是由脚本按参数绘制出来的：

```sh
python3 script/make_app_icon.py Resources
```

脚本顶部集中了所有可调参数（渐变色、圆弧半径、笔画宽度、箭头比例等），改完重跑即可。依赖 `pillow`。

输出是 1024×1024 满幅、完全不透明的方图，自己不做圆角也不烘焙投影。macOS 26 一旦在 `.icns` 里发现透明像素，就会把它当成旧格式图标，塞进一块灰色玻璃底板里缩小显示，于是出现双层圆角套框；交满幅不透明方图，系统才会自己套上正确的圆角、投影和玻璃边缘。改图标时注意别把这条规则改回旧的「1024 画布内 824 图形」布局。

## 目录结构

```text
AppMint/
├── Package.swift
├── script/
│   └── build_and_run.sh
├── AppMint/
│   ├── Models/
│   ├── Services/
│   ├── Store/
│   ├── Views/
│   └── Resources/
├── AppMintTests/
└── 需求文档.md
```

## 首版边界

- 原生 Mac App Store 应用支持直接更新；安装在 Mac 上的 iPhone/iPad 应用仍跳转至官方商店。
- Sparkle 应用在 Appcast 含 HTTPS 安装包时支持直接更新；仅含说明、动态生成或需要鉴权的 Feed 仍打开应用处理。
- Electron-builder 仅处理 `provider: github` 与带 HTTPS 地址的 `provider: generic`；`custom`、localhost、空地址等不安全配置仍交给应用自身。
- Tauri updater 仅处理 HTTPS 的 `latest.json` / `update-proxy.json`，并安装当前架构的 `.app` 压缩包。
- GitHub Releases 仅接受应用包中明确的稳定版接口，仓库名必须与应用名或 Bundle ID 对应；自动安装还会核对开发者签名。
- Homebrew 通常不提供发行说明，因此详情可能只有版本与主页。
- 动态或需要鉴权的更新源不会被强行解析。
- 脚本可以生成 `.app` 和 DMG；公开分发前仍需配置 Developer ID 签名、公证和正式应用图标。
