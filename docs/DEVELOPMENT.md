# 开发者文档

## 从源码运行

需要 **Xcode 26 或更高版本**、**Swift 6.2 或更高版本**。项目使用 SwiftUI 和 Swift Package Manager，没有第三方 Swift 包依赖。

```sh
git clone https://github.com/swiftczz/UpKeep.git
cd UpKeep

# 编译 Debug 版本，组装为 .app 并启动（会先退出正在运行的 Upkeep）
./scripts/build_and_run.sh

# 运行测试
swift test
```

也可以用 Xcode 打开根目录的 `Package.swift`，选择 Upkeep scheme 运行。完整的应用包和后台助手由构建脚本组装；`swift run Upkeep` 只运行裸二进制，没有后台助手。

其他启动方式：

```sh
./scripts/build_and_run.sh --debug   # 在 lldb 中启动
./scripts/build_and_run.sh --logs    # 启动并跟踪系统日志
./scripts/build_and_run.sh --verify  # 启动后确认进程正常运行
```

部分测试会读取本机 `/Applications` 中的真实应用，应用不存在时自动跳过。辅助进程相关的测试需要 C 编译器（`/usr/bin/cc`）来生成测试用的小程序。

## 构建发布包

```sh
./scripts/build_and_run.sh --build-only --sign --dmg
```

产物：

- `dist/Upkeep.app`：包含主程序和后台助手的应用包。
- `dist/Upkeep-<版本号>.dmg`：带"应用程序"快捷方式的安装镜像。

主程序和后台助手都构建为 arm64。

- **版本号**：优先使用 `APP_VERSION`，否则取最近的 Git tag，没有 tag 时为 `0.1.0-dev`。
- **构建号**：优先使用 `APP_BUILD`，否则取当前的 Git 提交数。
- **签名**：`--sign` 优先使用 `SIGN_IDENTITY`，其次是 `DEVELOPMENT_SIGN_IDENTITY` 或本机的 Apple Development 证书；都没有时使用 Ad-hoc 签名。面向外部分发的 Developer ID 签名和公证需要另外配置。

推送 `v*` 标签后，GitHub Actions（`.github/workflows/release.yml`）会构建 DMG、生成更新记录并上传到对应的 Release。手动运行工作流时，DMG 作为工作流附件提供。

### GitHub 浏览器授权

在 GitHub 注册一个 OAuth App 并启用 **Device Flow**，这是开发者的一次性配置。授权不申请额外 scope，应用中也不嵌入 Client Secret。未配置 Client ID 时，应用只提供访问令牌连接。

本地构建时设置 `UPKEEP_GITHUB_CLIENT_ID`，构建脚本会把这个公开标识写入应用的 `GitHubOAuthClientID`；发布构建读取同名的 GitHub Actions 仓库变量。

```sh
UPKEEP_GITHUB_CLIENT_ID="你的公开ClientID" ./scripts/build_and_run.sh
```

### 修改图标

调整 `scripts/make_app_icon.py` 中的颜色和几何参数后运行（需要 Pillow）：

```sh
python3 scripts/make_app_icon.py Resources
```

使用不透明的 1024 × 1024 方图，圆角和阴影交给系统处理。

## 项目结构

```text
Package.swift                       Swift Package Manager 配置
Resources/                          应用图标
scripts/                            构建、打包、更新记录与图标脚本
docs/                               用户与开发者文档
Upkeep/
  Models/                           应用记录、显示、搜索
    Updates/                        更新来源、机制、配置、状态、进度、接收版本
  Services/                         更新说明解析、安装、卸载与系统服务
    Updates/
      Sources/                      更新源协议、内置更新源与注册表
      Detection/                    扫描应用，识别更新方式
      Providers/                    按更新机制检查和安装更新
      Parsing/                      统一的发布信息与 JSON 解析
      Rules/                        声明式更新规则、内置规则与规则文件加载
      UpdateCoordinator.swift       按注册表调度检查与更新
  Store/                            应用列表状态与本地快照
  Views/                            侧栏、详情、卸载与设置界面
UpkeepPrivilegedHelper/             后台助手：安装 PKG、卸载受保护应用、停止系统后台服务
UpkeepPrivilegedHelperProtocol/     主程序与后台助手共用的 XPC 协议和校验规则
UpkeepTests/                        主程序测试
UpkeepPrivilegedHelperTests/        后台助手测试
```

## 更新流程

### 配置与显示

- `UpdateConfiguration` 描述一种更新方式：`mechanism`（协议）、`feedURL`、`identifier`、`homepageURL` 和 GitHub 发布标签前缀。
- `UpdateMechanism` 是协议，比如 Sparkle、Electron Updater；它的显示名称、搜索词、能否作为备用方式、检查条件和来源推导都集中在 `UpdateMechanism.traits` 中。
- `UpdateChannel` 是界面上的"更新来源"（App Store、Homebrew、GitHub、Website、Unknown），由机制和地址推导。

每个应用记录保存三份配置：

| 字段 | 含义 |
| --- | --- |
| `updateConfiguration` | 当前用来检查和更新的方式 |
| `alternateUpdateConfiguration` | 备用方式，比如 Homebrew 应用自带的 Sparkle |
| `installedUpdateConfiguration` | 上一次实际安装它的方式 |

界面显示的来源由 `displayedUpdateConfiguration` 决定：有待安装的更新时显示 `updateConfiguration`，否则显示 `installedUpdateConfiguration`。

### 识别与检查

更新源分两部分，都注册在 `UpdateSourceRegistry.standard` 中：

- **`UpdateSourceDetector`**：从已安装的应用识别更新方式。按注册顺序执行，第一个结果生效：App Store 收据、Info.plist 中声明的 Sparkle 地址、更新规则、Sparkle 框架、Electron 和 VS Code 配置、可执行文件中的更新地址，最后是兜底规则。
- **`UpdateSourceProvider`**：按机制检查和安装更新。`UpdateCoordinator` 只按机制查表，不包含具体协议的分支。Homebrew 这种一次处理整个列表的来源实现 `UpdateLibraryEnricher`。

Homebrew 应用如果还有备用方式，会先用 Homebrew 批量检查，再用备用方式检查；两边都有更新时取版本较新的一方，版本相同时用 Homebrew。

JSON 接口的结果统一为 `ReleaseCandidate`：规则用 `RuleJSONReleaseParser` 按指定字段读取，自动发现的接口用 `HeuristicJSONReleaseParser` 兼容常见字段。

### 接收版本

`PrereleasePolicy`（自动、仅正式版、正式版和预览版）按 Bundle ID 保存在 UserDefaults 中，不写入应用快照。`AppLibrary` 在每次检查和更新前把它附加到记录上，各 provider 通过 `AppRecord.acceptsPrereleases` 决定是否接受预览版。

## 接入新的更新方式

按情况选择最简单的一种：

1. **只有 JSON 接口、GitHub 仓库，或已支持更新器的地址**：写一条更新规则。内置规则放在 `BuiltInUpdateSourceRules.swift`，格式和用户规则文件相同，见 [自定义更新规则](UPDATE_RULES.md)。能用规则解决的，不要为单个应用写专门的识别代码。
2. **已有协议的新识别方式**：新增一个 `UpdateSourceDetector`，插入注册表中合适的位置。
3. **全新的协议**：在 `UpdateMechanism` 中新增机制并补充 `traits`，实现 `UpdateSourceProvider`（通常还需要识别器），再注册到 `UpdateSourceRegistry.standard`。

## 后台助手

后台助手以 root 身份运行，通过 `SMAppService` 注册，只接受签名与 Upkeep 一致的调用，并且每项操作都会再次确认调用者是管理员。目前提供：

- 安装 App Store 和开发者签名的 PKG。
- 把 `/Applications` 中受保护的应用移到当前用户的废纸篓。
- 停止某个应用注册的系统级 launchd 服务。助手根据应用路径自己查找服务，只会停止程序位于该应用包内的服务。

需要主程序和助手共同遵守的规则（比如 `PrivilegedTrashPolicy`、`LaunchJobPolicy`）放在 `UpkeepPrivilegedHelperProtocol` 中。
