#!/bin/zsh
set -eu
cd "${0:A:h}/.."
scanmacTestStage=$(mktemp -d /private/tmp/scanmac-codex-test.XXXXXX)
trap 'rm -rf "$scanmacTestStage"' EXIT
xcrun swiftc Source/CodexLocal.swift Tests/CodexLocalHarness.swift -parse-as-library -swift-version 5 -module-cache-path "$scanmacTestStage/cache" -o "$scanmacTestStage/TestCodexLocal"
"$scanmacTestStage/TestCodexLocal" "$scanmacTestStage/runtime" "${1:-openai/gpt-oss-20b}"
