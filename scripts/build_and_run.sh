#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Upkeep"
BUNDLE_ID="com.chengzhong.Upkeep"
HELPER_NAME="UpkeepPrivilegedHelper"
HELPER_LABEL="com.chengzhong.Upkeep.PrivilegedHelper"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_LAUNCH_DAEMONS="$APP_CONTENTS/Library/LaunchDaemons"
APP_BINARY="$APP_MACOS/$APP_NAME"
HELPER_BINARY="$APP_MACOS/$HELPER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
HELPER_PLIST="$APP_LAUNCH_DAEMONS/$HELPER_LABEL.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
THIRD_PARTY_NOTICES_SOURCE="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
STAGING_DIR=""

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

# 版本号优先级：APP_VERSION > 最近的 Git tag > 0.1.0-dev。
if [[ -z "${APP_VERSION:-}" ]]; then
  if tag=$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null); then
    APP_VERSION="${tag#v}"
  else
    APP_VERSION="0.1.0-dev"
  fi
fi

# 构建号优先级：APP_BUILD > 当前提交数 > 1。
if [[ -z "${APP_BUILD:-}" ]]; then
  APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

write_info_plist() {
  local icon_entry=""
  if [[ -f "$ICON_SOURCE" ]]; then
    icon_entry=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
$icon_entry
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>用于将你确认卸载的应用和关联文件移到废纸篓。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  plutil -lint "$INFO_PLIST" >/dev/null
}

write_helper_plist() {
  cat >"$HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/$HELPER_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HELPER_NAME</string>
  </array>
  <key>MachServices</key>
  <dict>
    <key>$HELPER_LABEL</key>
    <true/>
  </dict>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

  plutil -lint "$HELPER_PLIST" >/dev/null
}

development_signing_identity() {
  if [[ -n "${DEVELOPMENT_SIGN_IDENTITY:-}" ]]; then
    echo "$DEVELOPMENT_SIGN_IDENTITY"
    return
  fi

  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '/"Apple Development:/{print $2; exit}'
}

# 嵌套助手必须先单独签名，再签外层 .app。不要用 --deep：
# 对已签名的助手再 --deep 会导致 “nested code is modified or invalid”。
codesign_item() {
  local path="$1"
  local identifier="$2"
  local identity="$3"
  local requirements="${4:-}"
  shift 4 || true

  local args=(--force --sign)
  if [[ -z "$identity" || "$identity" == "-" ]]; then
    args+=(-)
  else
    args+=("$identity")
  fi
  args+=(--identifier "$identifier")
  if [[ -n "$requirements" ]]; then
    args+=(--requirements "$requirements")
  fi
  args+=("$@")
  codesign "${args[@]}" "$path"
}

sign_bundle() {
  local identity="${1:-}"
  local hardened="${2:-0}"
  if [[ -z "$identity" || "$identity" == "-" ]]; then
    echo "==> 使用带固定要求的 Ad-hoc 签名"
    codesign_item "$HELPER_BINARY" "$HELPER_LABEL" "-" \
      "=designated => identifier \"$HELPER_LABEL\""
    codesign_item "$APP_BUNDLE" "$BUNDLE_ID" "-" \
      "=designated => identifier \"$BUNDLE_ID\""
  else
    echo "==> 使用代码签名：$identity"
    # macOS Bash 3.2 treats an empty array as unset under `set -u`.
    if [[ "$hardened" == "1" ]]; then
      codesign_item "$HELPER_BINARY" "$HELPER_LABEL" "$identity" "" --options runtime --timestamp
      codesign_item "$APP_BUNDLE" "$BUNDLE_ID" "$identity" "" --options runtime --timestamp
    else
      codesign_item "$HELPER_BINARY" "$HELPER_LABEL" "$identity" ""
      codesign_item "$APP_BUNDLE" "$BUNDLE_ID" "$identity" ""
    fi
  fi

  codesign --verify --strict --verbose=2 "$HELPER_BINARY"
  test -s "$APP_CONTENTS/_CodeSignature/CodeResources"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_development_app() {
  local identity
  identity="$(development_signing_identity)"

  if [[ -n "$identity" && "$identity" != "-" ]]; then
    echo "==> 使用稳定的本地开发签名：$identity"
    sign_bundle "$identity" 0
    return
  fi

  sign_bundle "-" 0
}

package_app_from_binary() {
  local build_binary="$1"
  local helper_build_binary="$2"

  case "$APP_BUNDLE" in
    "$DIST_DIR"/*.app) ;;
    *) echo "拒绝清理非 dist 目录中的应用包：$APP_BUNDLE" >&2; exit 1 ;;
  esac

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_LAUNCH_DAEMONS"
  ditto "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  ditto "$helper_build_binary" "$HELPER_BINARY"
  chmod +x "$HELPER_BINARY"

  if [[ -f "$ICON_SOURCE" ]]; then
    ditto "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
  fi

  if [[ -f "$THIRD_PARTY_NOTICES_SOURCE" ]]; then
    ditto "$THIRD_PARTY_NOTICES_SOURCE" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
  fi

  write_info_plist
  write_helper_plist
}

sign_app() {
  local identity="${SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(development_signing_identity)"
  fi

  if [[ -z "$identity" || "$identity" == "-" ]]; then
    sign_bundle "-" 0
  else
    sign_bundle "$identity" 1
  fi
}

create_dmg() {
  local dmg_path="$DIST_DIR/${APP_NAME}-${APP_VERSION}.dmg"

  rm -f "$dmg_path"
  STAGING_DIR="$(mktemp -d)"
  ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$STAGING_DIR/Applications"

  diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$STAGING_DIR" \
    "$dmg_path" >/dev/null

  rm -rf "$STAGING_DIR"
  STAGING_DIR=""
  echo "==> DMG：$dmg_path"
}

build_only() {
  local build_args=(-c release --arch arm64)
  local should_sign=0
  local should_create_dmg=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      arm64) ;; # 兼容旧的显式 arm64 调用。
      --sign) should_sign=1 ;;
      --dmg) should_create_dmg=1 ;;
      *) echo "未知选项：$1" >&2; exit 2 ;;
    esac
    shift
  done

  mkdir -p "$DIST_DIR"

  echo "==> 编译 ${APP_NAME}（arm64，版本 ${APP_VERSION}，构建 ${APP_BUILD}）"
  swift build --package-path "$ROOT_DIR" --product "$APP_NAME" "${build_args[@]}"
  swift build --package-path "$ROOT_DIR" --product "$HELPER_NAME" "${build_args[@]}"

  local build_dir
  local build_binary
  local helper_build_binary
  build_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path "${build_args[@]}")"
  build_binary="$build_dir/$APP_NAME"
  helper_build_binary="$build_dir/$HELPER_NAME"
  package_app_from_binary "$build_binary" "$helper_build_binary"

  if [[ $should_sign -eq 1 ]]; then
    sign_app
  else
    sign_development_app
  fi

  if [[ $should_create_dmg -eq 1 ]]; then
    create_dmg
  fi

  echo "==> 应用包：$APP_BUNDLE"
}

build_debug_app() {
  mkdir -p "$DIST_DIR"
  swift build --package-path "$ROOT_DIR" --product "$APP_NAME" --arch arm64
  swift build --package-path "$ROOT_DIR" --product "$HELPER_NAME" --arch arm64

  local build_dir
  build_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path --arch arm64)"
  package_app_from_binary "$build_dir/$APP_NAME" "$build_dir/$HELPER_NAME"
  sign_development_app
}

quit_running_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
}

register_app() {
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

open_app() {
  register_app
  quit_running_app
  local attempt
  local open_error=""
  for attempt in {1..5}; do
    open_error="$(/usr/bin/open "$APP_BUNDLE" 2>&1)" || true
    for _ in {1..15}; do
      if /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
        return 0
      fi
      sleep 0.1
    done
    sleep 0.3
  done
  if [[ -n "$open_error" ]]; then
    echo "$open_error" >&2
  fi
  echo "无法打开 $APP_BUNDLE" >&2
  return 1
}

usage() {
  echo "用法：$0 [run|--build-only [--sign] [--dmg]|--debug|--logs|--verify]（仅 arm64）" >&2
}

case "$MODE" in
  --build-only|build-only)
    build_only "${@:2}"
    ;;
  run)
    quit_running_app
    build_debug_app
    open_app
    ;;
  --debug|debug)
    quit_running_app
    build_debug_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    quit_running_app
    build_debug_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    quit_running_app
    build_debug_app
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "==> $APP_NAME 已成功启动"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
