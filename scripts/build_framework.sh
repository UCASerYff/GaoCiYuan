#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
XCODE=/Applications/Xcode.app
if [[ ! -d "$XCODE/Contents/Developer" ]]; then
    echo "error: 未找到 Xcode（$XCODE）。构建需要完整 Xcode 工具链（SwiftUI 宏插件只随 Xcode 分发），" >&2
    echo "       请安装 Xcode 后重试；仅用 Command Line Tools 无法构建。" >&2
    exit 1
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"
NAME=Token
SOURCE="$ROOT"
[[ -d "$SOURCE/Sources" && -f "$SOURCE/Module.swift" ]] || { echo "Unknown module: $NAME" >&2; exit 1; }
BUILD="$ROOT/build.noindex"
FRAMEWORK="$BUILD/Frameworks/$NAME.framework"
VERSION="$FRAMEWORK/Versions/A"
rm -rf "$FRAMEWORK"
mkdir -p "$VERSION/Modules/$NAME.swiftmodule" "$VERSION/Resources" "$BUILD/cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
[[ -f "$MACROS" ]] || { echo "error: SwiftUI 宏插件缺失：$MACROS（Xcode 安装不完整？）" >&2; exit 1; }
SOURCES=("$SOURCE"/Sources/*.swift "$SOURCE"/Shared/*.swift(N) "$SOURCE/Module.swift")
swiftc -swift-version 5 -parse-as-library -O -emit-library -emit-module \
    -module-name "$NAME" -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$BUILD/cache" -load-plugin-library "$MACROS" \
    -framework SwiftUI -framework AppKit -framework Charts \
    -framework CryptoKit -framework AppIntents -framework WebKit \
    -framework UniformTypeIdentifiers -framework Security -framework PDFKit \
    -framework QuickLookUI -framework UserNotifications -framework Combine \
    -framework CoreText -framework ImageIO -lsqlite3 \
    -Xlinker -install_name -Xlinker "@rpath/$NAME.framework/Versions/A/$NAME" \
    $SOURCES \
    -emit-module-path "$VERSION/Modules/$NAME.swiftmodule/arm64-apple-macos.swiftmodule" \
    -o "$VERSION/$NAME"
ditto "$SOURCE/Resources" "$VERSION/Resources"
python3 - "$ROOT/Info.plist" "$NAME" "$VERSION/Resources/Info.plist" <<'PYINFO'
import plistlib,sys
with open(sys.argv[1],'rb') as f: app=plistlib.load(f)
data={'CFBundleIdentifier':app['CFBundleIdentifier']+'.framework','CFBundleName':app['CFBundleName'],'CFBundleExecutable':sys.argv[2],'CFBundlePackageType':'FMWK','CFBundleShortVersionString':app['CFBundleShortVersionString'],'CFBundleVersion':app['CFBundleVersion']}
with open(sys.argv[3],'wb') as f:plistlib.dump(data,f)
PYINFO

ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/$NAME "$FRAMEWORK/$NAME"
ln -s Versions/Current/Modules "$FRAMEWORK/Modules"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
codesign --force --sign - "$FRAMEWORK"
echo "Built $FRAMEWORK"
