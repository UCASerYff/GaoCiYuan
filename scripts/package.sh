#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
APP=${GAO_PACKAGE_APP:-"$ROOT/build.noindex/搞词元.app"}
STAGE="$ROOT/.release.noindex"
RELEASE_APP="$STAGE/搞词元.app"
SIGNING_IDENTITY=${GAO_SIGNING_IDENTITY:-A15B2B2D22B018CBC842063C9A8A589946647524}
codesign --verify --deep --strict "$APP"
[[ ! -d "$APP/Contents/PlugIns/GaoCiYuanWidgets.appex" ]] || { echo '构建仍包含已移除的小组件，请重新构建';exit 1;}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")" ]] || { echo '构建版本与源码版本不一致';exit 1;}
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$RELEASE_APP"
python3 "$ROOT/scripts/sanitize_bundle.py" "$RELEASE_APP"
for helper in "$RELEASE_APP"/Contents/Frameworks/Token.framework/Versions/A/Resources/UsageEngine/tokscale(N); do
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$helper"
done
codesign --force --sign "$SIGNING_IDENTITY" "$RELEASE_APP/Contents/Frameworks/Token.framework"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/App.entitlements" "$RELEASE_APP"
codesign --verify --deep --strict "$RELEASE_APP"
ditto -c -k --keepParent --norsrc --noextattr "$RELEASE_APP" "$ROOT/dist/GaoCiYuan-$VERSION.zip"
(cd "$ROOT/dist"; shasum -a 256 "GaoCiYuan-$VERSION.zip" > "GaoCiYuan-$VERSION.zip.sha256")
echo "Packaged $ROOT/dist/GaoCiYuan-$VERSION.zip"
