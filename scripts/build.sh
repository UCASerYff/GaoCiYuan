#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
APP="$BUILD/搞词元.app"
SIGNING_IDENTITY=${GAO_SIGNING_IDENTITY:-A15B2B2D22B018CBC842063C9A8A589946647524}
[[ -d "$DEVELOPER_DIR" ]] || { echo '需要完整 Xcode';exit 1; }
mkdir -p "$BUILD/cache" "$BUILD/icon.iconset"
if [[ "${1:-}" != "--skip-frameworks" ]]; then
    "$ROOT/scripts/build_framework.sh" > "$BUILD/framework-build.log" 2>&1 || { tail -60 "$BUILD/framework-build.log";exit 1;}
    "$ROOT/scripts/build_widgets.sh" > "$BUILD/widget-build.log" 2>&1 || { tail -60 "$BUILD/widget-build.log";exit 1;}
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/GaoCiYuanIcon.png" --out "$BUILD/icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size*2))
    sips -z $double $double "$ROOT/Resources/GaoCiYuanIcon.png" --out "$BUILD/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 "$ROOT/scripts/pack_icon.py" "$BUILD/icon.iconset" "$APP/Contents/Resources/GaoCiYuan.icns"
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/cache" -load-plugin-library "$MACROS" -F "$BUILD/Frameworks" -framework Token -framework AppKit -framework SwiftUI -framework UserNotifications -framework CryptoKit -lsqlite3 -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$ROOT/Host/"*.swift -o "$APP/Contents/MacOS/GaoCiYuan"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/GaoCiYuanIcon.png" "$APP/Contents/Resources/"
ditto "$BUILD/Frameworks/Token.framework" "$APP/Contents/Frameworks/Token.framework"
for helper in "$APP"/Contents/Frameworks/Token.framework/Versions/A/Resources/UsageEngine/tokscale(N); do codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$helper"; done
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/Token.framework"
ditto "$BUILD/PlugIns/GaoCiYuanWidgets.appex" "$APP/Contents/PlugIns/GaoCiYuanWidgets.appex"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/Widget.entitlements" "$APP/Contents/PlugIns/GaoCiYuanWidgets.appex"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
