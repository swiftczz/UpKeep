# 自定义更新规则

有些应用 Upkeep 无法自动识别，但你知道它的更新地址，比如它只提供一个 JSON 接口、一个 GitHub 仓库，或者把更新地址写在了代码里。这时可以写一个规则文件告诉 Upkeep 去哪里检查，不需要修改 Upkeep 的代码。

## 放在哪里

把 `.json` 文件放进：

```
~/Library/Application Support/Upkeep/UpdateSources/
```

也可以在 **设置 › 自定义更新规则** 中点击"打开文件夹"。放好后点击"重新载入"，或等下次检查更新时生效。

- 一个文件可以写一条规则，也可以写一个规则数组。
- 文件按名称排序；`id` 相同的规则以靠前的文件为准，并会覆盖 Upkeep 内置的同名规则。
- 规则写错时，"设置"里会列出出错的文件和原因。

## 三种规则

### 1. JSON 接口（`jsonFeed`）

应用的更新接口返回 JSON，用 `fields` 告诉 Upkeep 每个字段在哪里：

```json
{
  "id": "example-editor",
  "name": "Example Editor",
  "kind": "jsonFeed",
  "match": { "bundleIdentifier": "com.example.editor" },
  "feed": "https://example.com/api/update?arch={arch}&version={version}",
  "fields": {
    "version": ["latest.version", "version"],
    "notes": ["latest.notes.zh-CN", "latest.notes.en"],
    "date": "latest.published_at",
    "assets": "latest.downloads",
    "assetURL": "url",
    "assetSHA256": "sha256",
    "assetSize": "size"
  }
}
```

### 2. GitHub 仓库（`githubReleases`）

应用在 GitHub Releases 发布新版本：

```json
{
  "id": "example-app",
  "kind": "githubReleases",
  "match": { "bundleIdentifier": "com.example.app" },
  "repository": "example/app",
  "tagPrefix": "desktop-v",
  "assetNamePrefix": "ExampleApp-"
}
```

- `repository`：`owner/name` 形式，可以使用占位符，比如 `example/{slug}`。
- `tagPrefix`（可选）：同一个仓库还发布了 CLI、移动版等其他产品时，只看标签以此开头的版本，比如 `desktop-v`。
- `assetNamePrefix`（可选）：只选择文件名以此开头的安装包。

### 3. 已支持的更新器（`updaterFeed`）

应用使用 Upkeep 已经支持的更新格式，只是地址无法自动找到：

```json
{
  "id": "example-chat",
  "kind": "updaterFeed",
  "format": "electronBuilder",
  "match": { "bundleIdentifier": "com.example.chat" },
  "feed": "https://downloads.example.com/latest-mac.yml"
}
```

`format` 可以是：

| 取值 | 格式 |
| --- | --- |
| `electronBuilder` | Electron 应用的 `latest-mac.yml` |
| `sparkle` | Sparkle 的 appcast |
| `tauri` | Tauri 更新清单，或者列出各版本清单的 `versions.json` 目录 |

版本判断、安装包选择和校验，和自动识别到的同类应用完全一样。

## 字段说明

| 字段 | 说明 |
| --- | --- |
| `id` | 规则标识，只能用小写字母、数字、点、下划线和连字符，最长 64 个字符 |
| `name` | 可选，显示在错误信息中的名称 |
| `kind` | `jsonFeed`、`githubReleases` 或 `updaterFeed` |
| `match` | `bundleIdentifier` 精确匹配；或 `bundleIdentifierPattern` 用正则匹配完整的 Bundle ID，二选一 |
| `feed` | `jsonFeed` 和 `updaterFeed` 的地址，必须是 HTTPS |
| `homepage` | 可选，应用主页，必须是 HTTPS |
| `releaseNotes` | 可选，更新说明另外发布在别处时的地址，可以用 `{latestVersion}` 表示检查到的新版本号。仅用于 `jsonFeed` 和 `updaterFeed` |
| `precedence` | 可选，见下文 |
| `fields` | `jsonFeed` 专用，见下文 |

### 占位符

地址和仓库名中可以使用：

| 占位符 | 含义 |
| --- | --- |
| `{version}` | 已安装的版本号 |
| `{build}` | 已安装的构建号 |
| `{bundleIdentifier}` | 应用的 Bundle ID |
| `{arch}` | 本机架构：`arm64` 或 `x64` |
| `{latestVersion}` | 检查到的新版本号，仅用于 `releaseNotes` |
| `{名称}` | `bundleIdentifierPattern` 中的命名分组，比如 `(?<slug>...)` |

地址中的占位符会自动做 URL 编码，版本号里的特殊字符不会破坏地址。

例如，一个应用的更新说明发布在 GitHub，可以这样写：

```json
"releaseNotes": "https://github.com/example/app/releases/tag/v{latestVersion}"
```

### `fields`（JSON 接口）

用点号路径读取 JSON，比如 `release.assets.0.url`；`$` 表示整个响应。每个字段都可以写成数组，列出多个候选路径，取第一个有值的。

| 字段 | 说明 |
| --- | --- |
| `version` | 必填，版本号 |
| `notes` | 更新说明 |
| `notesURL` | 更新说明页面 |
| `date` | 发布日期，支持 ISO 8601 和秒/毫秒时间戳 |
| `assets` | 安装包列表：数组、以名称为键的对象，或单个安装包；省略时，整个响应就是唯一的安装包 |
| `assetURL` | 每个安装包中下载地址的路径，默认 `url` |
| `assetName` | 安装包名称 |
| `assetSHA256` / `assetSHA512` | 校验值 |
| `assetSize` | 安装包大小 |

### `precedence`

- `beforeHeuristics`（默认）：优先于 Upkeep 自己推断出来的更新方式，但不会覆盖 App Store，也不会覆盖应用在 Info.plist 中声明的 Sparkle 地址。
- `fallback`：只在 Upkeep 完全识别不出来时才使用。

## 规则不会放宽安全检查

规则只决定"去哪里检查、怎么读"，不会降低安装时的检查：

- 下载必须使用 HTTPS。
- 安装包的 Bundle ID 必须和已安装的应用一致。
- 代码签名必须有效；已安装的应用有开发者签名时，新版本必须来自同一个开发者（Team ID 一致）。

无论更新最终由哪种方式安装，这些检查都会执行。
