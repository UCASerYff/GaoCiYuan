#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -d "$DEVELOPER_DIR" ]]

mkdir -p .test.noindex
fixture="$(mktemp -d "$PWD/.test.noindex/macos-verify.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

# Use the production compile/link steps without a distribution identity.
GAO_SIGNING_IDENTITY=- /bin/zsh scripts/build.sh
app=build.noindex/搞词元.app
framework="$app/Contents/Frameworks/Token.framework/Versions/A"
[[ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/GaoCiYuan")" == arm64 ]]
[[ "$(/usr/bin/lipo -archs "$framework/Token")" == arm64 ]]
for info in Info.plist "$app/Contents/Info.plist" "$framework/Resources/Info.plist"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == 4.15 ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" == 17 ]]
done
[[ ! -e "$app/Contents/PlugIns/GaoCiYuanWidgets.appex" ]]
python3 - "$app/Contents/MacOS/GaoCiYuan" <<'PY'
import subprocess
import sys

subprocess.run([sys.argv[1], "--capture-antigravity-status"], input=b"{}", check=True, timeout=15)
PY

compiler=(xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0)
models=(Sources/{Models,AgentTables,ProviderIntegrations,GrokBotUsageReport,QuotaForecast}.swift)

"${compiler[@]}" "${models[@]}" Sources/{Alerts,Log}.swift Tests/QuotaForecastRegression.swift \
    -framework UserNotifications -o "$fixture/quota-forecast"
"$fixture/quota-forecast"

"${compiler[@]}" "${models[@]}" Sources/{AntigravityUsageReport,Log}.swift Tests/AntigravityUsageReportRegression.swift -o "$fixture/antigravity-report"
"$fixture/antigravity-report"

"${compiler[@]}" "${models[@]}" Sources/{AntigravityStatusLine,Log}.swift Tests/AntigravityStatusLineRegression.swift \
    -framework CryptoKit -o "$fixture/antigravity-statusline"
"$fixture/antigravity-statusline"

"${compiler[@]}" "${models[@]}" Sources/{AntigravityDesktopQuota,GeminiEmbeddedAntigravityQuota,GeminiAntigravityAccountReader,AntigravityStatusLine,Log}.swift \
    Tests/AntigravityDesktopQuotaRegression.swift -framework AppKit -framework ApplicationServices \
    -framework CryptoKit -o "$fixture/antigravity-desktop-quota"
"$fixture/antigravity-desktop-quota"

"${compiler[@]}" Sources/TokenLifecycleWork.swift Tests/TokenLifecycleWorkRegression.swift -o "$fixture/lifecycle"
"$fixture/lifecycle"

"${compiler[@]}" "${models[@]}" \
    Sources/{Pacing,RefreshCoordinator,MonitorStore,LegacyAccountMigration,UsageAnalyticsStore,TokenLifecycleWork,AntigravityStatusLine}.swift \
    Tests/RefreshSchedulingRegression.swift -framework SwiftUI -framework AppKit \
    -framework UniformTypeIdentifiers -framework CryptoKit -lsqlite3 -o "$fixture/refresh"
"$fixture/refresh"

"${compiler[@]}" Tests/CompactAgentUIRegression.swift -o "$fixture/compact-ui"
"$fixture/compact-ui"

"${compiler[@]}" Sources/{GrokBotUsageReport,GrokBotAX,AXShared}.swift Tests/GrokBotAXRegression.swift \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -o "$fixture/grok-ax"
"$fixture/grok-ax"

python3 Tests/InstallNoBackupRegression.py
