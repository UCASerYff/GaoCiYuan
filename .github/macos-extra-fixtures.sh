#!/usr/bin/env bash
set -uo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || exit 1
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p .test.noindex || exit 1
scratch="$(mktemp -d "$PWD/.test.noindex/extra-macos.XXXXXX")" || exit 1
server_pid=''
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

compiler=(xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$scratch/cache")
models=(Sources/{Models,AgentTables,ProviderIntegrations,GrokBotUsageReport,QuotaForecast}.swift)
http=(Sources/BoundedHTTP.swift -framework CryptoKit)
cursor=(Sources/CursorUsageBridge.swift Tests/CursorUsageFixtureSupport.swift "${http[@]}")
usage=(Sources/UsageEngine.swift "${cursor[@]}")
ledger=(Sources/UsageLedger.swift "${usage[@]}" -lsqlite3)
binary="$PWD/Resources/UsageEngine/tokscale"
failed=0

check() {
    local name="$1" compile_result=0 run_result=0
    shift
    local compile_args=() run_args=()
    while (( $# )) && [[ "$1" != -- ]]; do compile_args+=("$1"); shift; done
    if (( $# )); then shift; run_args=("$@"); fi
    echo "::group::$name"
    "${compiler[@]}" "${compile_args[@]}" "Tests/$name.swift" -o "$scratch/$name" || compile_result=$?
    # Bash 3 calls an empty array unbound under set -u.
    if (( compile_result == 0 )); then "$scratch/$name" ${run_args[@]+"${run_args[@]}"} || run_result=$?; fi
    printf '%s compile=%s run=%s\n' "$name" "$compile_result" "$run_result"
    echo '::endgroup::'
    if (( compile_result || run_result )); then failed=$((failed + 1)); fi
}

printf 'func L(_ text: String) -> String { text }\n' > "$scratch/DiscoveryLocalization.swift"
check AgentDiscoveryRegression -D TESTING "${models[@]}" \
    Sources/{NativeMembers,GrokBotBridge,GrokBotAX,AXShared,Theme}.swift "$scratch/DiscoveryLocalization.swift" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices
check ProviderCatalogRegression "${models[@]}"
check GrokBotUsageReportRegression Sources/GrokBotUsageReport.swift
check ConnectorCancellationRegression Sources/ConnectorCancellation.swift
check CursorUsageRegression "${cursor[@]}" Sources/UsageEngine.swift Sources/UsageLedger.swift -lsqlite3
check CloudQuotaBridgeRegression "${models[@]}" Sources/ProviderCloudBridges.swift "${http[@]}"
check ProviderToolBridgeRegression Sources/ProviderToolBridges.swift "${http[@]}"
check UpdaterNetworkRegression Sources/Updater.swift "${http[@]}" -framework AppKit
check HTTPRequestBudgetRegression "${http[@]}"

python3 -B Tests/http_budget_server.py --port-file "$scratch/port" > "$scratch/loopback.log" &
server_pid=$!
for ((i=0;i<50;i++)); do [[ -s "$scratch/port" ]] && break; sleep .1; done
if [[ -s "$scratch/port" ]]; then
    check HTTPBudgetRegression "${http[@]}" -- "$(cat "$scratch/port")" "$scratch/http-report.json"
else
    echo 'HTTPBudgetRegression could not start its isolated loopback server' >&2
    failed=$((failed + 1))
fi

check UsageEnginePolicyRegression "${usage[@]}"
check UsageEngineRegression "${usage[@]}" -- "$binary"
check UsageEngineSQLiteRegression "${usage[@]}" -lsqlite3 -- "$binary"
check UsageDuplicateRegression "${ledger[@]}" -- "$binary"
check UsageLedgerRegression "${ledger[@]}"
check UsageModelObservationRegression "${ledger[@]}"
check UsageModelInferenceRegression "${ledger[@]}" -- "$binary"
python3 -B Tests/ClaudePanelIconResourceRegression.py || failed=$((failed + 1))

printf 'Additional isolated fixture failures: %s\n' "$failed"
(( failed == 0 ))
