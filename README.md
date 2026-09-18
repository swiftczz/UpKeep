# Upkeep

Upkeep 是 macOS 上的应用更新与卸载工具。它扫描本机已安装的 `.app`，判断每个应用实际用哪条更新通道，然后在同一个窗口里检查版本、安装更新，或把应用和关联文件一起移到废纸篓。

最低系统版本是 **macOS 26**，仅支持 **Apple Silicon（arm64）**。源码是 Swift 6.2 + SwiftUI，用 Swift Package Manager 组织，没有第三方 Swift 包。

## 如何使用

左侧是应用列表，右侧是详情。

列表分三组：

1. **可用更新** — 已发现新版本，且你没有忽略
2. **已安装的应用** — 已是最新，或不支持检查
3. **已忽略的更新** — 你主动忽略过的条目

侧栏可以按应用名、Bundle ID 或更新来源搜索。例如输入 `Sparkle`、`Homebrew`、`GitHub` 会只留下对应来源。

右侧详情显示当前版本、最新版本、发布日期、更新包大小、主页和发行说明。主按钮随状态变化：

- 能由 Upkeep 安装时，按钮是「更新」
- Mac App Store 应用因平台或商店区号对不上、必须去商店页时，会打开 App Store
- 没有可安装更新时，按钮是「打开」

主按钮右侧的菜单里还有「在 Finder 中显示」和「卸载」。

工具栏：

- **检查更新**（`⌘R`）重新扫描并检查全部应用
- **更新全部** 一次性安装所有可自动更新的条目；如果其中有正在运行的应用，会先弹出确认，更新时退出，装完再打开


## 如何编译

需要 Xcode 26 和 Swift 6.2。在仓库根目录：

```sh
# Debug 组装成 .app 并打开
./scripts/build_and_run.sh

# 带调试器
./scripts/build_and_run.sh --debug

# 打开后跟系统日志
./scripts/build_and_run.sh --logs

# 打开后确认进程还在
./scripts/build_and_run.sh --verify

# 测试
swift test
```

也可以用 Xcode 打开根目录的 `Package.swift`，选 Upkeep scheme 运行。不要直接 `swift run Upkeep`：那样只有裸二进制，没有 `.app` 包，也没有特权助手。

打 Release 包：

```sh
./scripts/build_and_run.sh --build-only --sign --dmg
```

主程序和安装助手统一构建为 arm64，每个版本只发布一个 `dist/Upkeep-<版本号>.dmg`，应用包为 `dist/Upkeep.app`。GitHub Release 流程也只构建、上传这一份 DMG。`--sign` 的证书顺序是：环境变量 `SIGN_IDENTITY` → 本机 Apple Development 证书 → 带固定 Bundle ID 要求的 Ad-hoc。`--dmg` 会再打一份带 Applications 快捷方式的磁盘镜像。

版本号：`APP_VERSION` 没设时用最近的 Git tag，没有 tag 就是 `0.1.0-dev`。构建号：`APP_BUILD` 没设时用当前提交数。

图标在 `Resources/AppIcon.icns`。要改外观，改 `scripts/make_app_icon.py` 顶部的颜色和几何参数，然后：

```sh
python3 scripts/make_app_icon.py Resources
```

需要 Pillow。输出必须是 1024×1024、没有透明像素的方图。macOS 26 看到 `.icns` 里有透明区域，会按旧图标处理，外面再套一层灰色玻璃底板。圆角和阴影交给系统加，不要画在图里。

对外分发还要自己做 Developer ID 签名和公证。

## 项目结构

```text
Package.swift                         SPM 清单
Resources/                            图标
scripts/build_and_run.sh              组装 .app / 签名 / DMG
scripts/make_app_icon.py              画图标
Upkeep/                               主程序
  Models/                             AppRecord、来源和状态
  Services/                           扫描、各更新通道、安装、卸载、进程
  Store/                              列表状态和本地缓存
  Views/                              侧栏、详情、卸载页
UpkeepPrivilegedHelper/               以 root 安装 App Store pkg
UpkeepPrivilegedHelperProtocol/       主程序和助手共用的 XPC 协议
UpkeepTests/
UpkeepPrivilegedHelperTests/
```

主程序链接 CoreServices、Security、ServiceManagement。助手只链接 Security。
