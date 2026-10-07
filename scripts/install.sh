#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
SOURCE="$ROOT/build.noindex/搞词元.app"
if [[ ! -d "$SOURCE" ]]; then
    SOURCE="$ROOT/.install.noindex/搞词元.app"
    mkdir -p "$ROOT/.install.noindex"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
    (cd "$ROOT/dist";shasum -a 256 -c "搞词元-$VERSION.zip.sha256")
    ditto -x -k "$ROOT/dist/搞词元-$VERSION.zip" "$ROOT/.install.noindex"
fi
TARGET="/Applications/搞词元.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
codesign --verify --deep --strict "$SOURCE"
[[ "$(codesign -dv "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "5G96498KGJ" ]] || { echo '需要团队签名';exit 1;}
if pgrep -f '^/Applications/搞词元.app/Contents/MacOS/GaoCiYuan' >/dev/null; then echo '请先退出当前应用';exit 1;fi
STAMP=$(date +%Y%m%d-%H%M%S)
SAFETY="$ROOT/rollback/搞词元-$STAMP.app"
mkdir -p "$ROOT/rollback"
if [[ -d "$TARGET" ]]; then mv "$TARGET" "$SAFETY";fi
if ! ditto "$SOURCE" "$TARGET" || ! codesign --verify --deep --strict "$TARGET" || ! "$LSREGISTER" -f -R "$TARGET"; then
    rm -rf "$TARGET"
    if [[ -d "$SAFETY" ]];then mv "$SAFETY" "$TARGET";"$LSREGISTER" -f -R "$TARGET";fi
    exit 1
fi
pluginkit -a "$TARGET/Contents/PlugIns/GaoCiYuanWidgets.appex"
killall -TERM GaoCiYuanWidgets 2>/dev/null || true
killall -TERM chronod 2>/dev/null || true
rm -rf "$ROOT/.install.noindex"
echo "Installed $TARGET"
