#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
mkdir -p "$BUILD/PlugIns" "$BUILD/widget-cache"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$BUILD/PlugIns/GaoCiYuanWidgets.appex/Contents/MacOS"
swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$BUILD/widget-cache" -sdk "$SDK" -target arm64-apple-macosx14.0 -Xlinker -e -Xlinker _NSExtensionMain -framework AppKit -framework SwiftUI -framework WidgetKit -framework Foundation "$ROOT/Sources/WidgetSnapshot.swift" "$ROOT/Widgets/GaoCiYuanWidgets.swift" -o "$BUILD/PlugIns/GaoCiYuanWidgets.appex/Contents/MacOS/GaoCiYuanWidgets"
cp "$ROOT/Widgets/Info.plist" "$BUILD/PlugIns/GaoCiYuanWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUILD/PlugIns/GaoCiYuanWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$BUILD/PlugIns/GaoCiYuanWidgets.appex/Contents/Info.plist"
