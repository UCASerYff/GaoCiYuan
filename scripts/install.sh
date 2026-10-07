#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
SOURCE="$ROOT/build.noindex/搞词元.app"
if [[ ! -d "$SOURCE" ]]; then
    SOURCE="$ROOT/.install.noindex/搞词元.app"
    mkdir -p "$ROOT/.install.noindex"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
    (cd "$ROOT/dist";shasum -a 256 -c "GaoCiYuan-$VERSION.zip.sha256")
    ditto -x -k "$ROOT/dist/GaoCiYuan-$VERSION.zip" "$ROOT/.install.noindex"
fi
TARGET="/Applications/搞词元.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
codesign --verify --deep --strict "$SOURCE"
[[ "$(codesign -dv "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "5G96498KGJ" ]] || { echo '需要团队签名';exit 1;}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")" ]] || { echo '安装版本与源码版本不一致';exit 1;}
[[ ! -d "$SOURCE/Contents/PlugIns/GaoCiYuanWidgets.appex" ]] || { echo '安装包仍包含已移除的小组件，请重新构建';exit 1;}
if pgrep -f '^/Applications/搞词元.app/Contents/MacOS/GaoCiYuan' >/dev/null; then echo '请先退出当前应用';exit 1;fi
STAMP=$(date +%Y%m%d-%H%M%S)
SAFETY="$ROOT/rollback/搞词元-$STAMP.app"
mkdir -p "$ROOT/rollback"
OLD_WIDGET="$TARGET/Contents/PlugIns/GaoCiYuanWidgets.appex"
OLD_WIDGET_REMOVED=false
restore_widget_registration() {
    if [[ "$OLD_WIDGET_REMOVED" == true && -d "$OLD_WIDGET" ]]; then
        pluginkit -a "$OLD_WIDGET"
    fi
}
if [[ -d "$OLD_WIDGET" ]]; then
    OLD_WIDGET_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD_WIDGET/Contents/Info.plist")
    [[ "$OLD_WIDGET_ID" == "com.gaoseries.GaoCiYuan.widgets" ]] || { echo "旧小组件标识不匹配：$OLD_WIDGET_ID";exit 1;}
    if ! pluginkit -r "$OLD_WIDGET"; then
        pluginkit -a "$OLD_WIDGET"
        echo '无法注销旧小组件，保留当前应用'
        exit 1
    fi
    OLD_WIDGET_REMOVED=true
    killall -TERM GaoCiYuanWidgets 2>/dev/null || true
fi
if [[ -d "$TARGET" ]] && ! mv "$TARGET" "$SAFETY"; then
    restore_widget_registration
    exit 1
fi
if ! ditto "$SOURCE" "$TARGET" || ! codesign --verify --deep --strict "$TARGET" || ! "$LSREGISTER" -f -R "$TARGET"; then
    rm -rf "$TARGET"
    if [[ -d "$SAFETY" ]]; then
        mv "$SAFETY" "$TARGET"
        "$LSREGISTER" -f -R "$TARGET"
        restore_widget_registration
    fi
    exit 1
fi
rm -rf "$ROOT/.install.noindex"
echo "Installed $TARGET"
