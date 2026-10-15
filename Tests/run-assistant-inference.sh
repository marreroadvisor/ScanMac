#!/bin/zsh
set -eu
cd "${0:A:h}/.."
scanmacInferenceStage=$(mktemp -d /private/tmp/scanmac-inference.XXXXXX)
trap 'rm -rf "$scanmacInferenceStage"' EXIT
xcrun swiftc Source/CodexLocal.swift Source/LocalNetworking.swift Source/AssistantInference.swift Tests/AssistantInferenceHarness.swift -parse-as-library -module-cache-path "$scanmacInferenceStage/cache" -o "$scanmacInferenceStage/Test"
"$scanmacInferenceStage/Test"
