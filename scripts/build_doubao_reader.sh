#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$ROOT/build.noindex/helpers" "$ROOT/build.noindex/cache"
xcrun swiftc -O -module-cache-path "$ROOT/build.noindex/cache" -framework AppKit "$ROOT/scripts/doubao-reader/main.swift" "$ROOT/Sources/AXShared.swift" "$ROOT/Sources/DoubaoAX.swift" "$ROOT/Sources/QuotaValueParser.swift" -o "$ROOT/build.noindex/helpers/doubao-reader"
codesign --force --sign "${GAO_SIGNING_IDENTITY:-A15B2B2D22B018CBC842063C9A8A589946647524}" "$ROOT/build.noindex/helpers/doubao-reader"
