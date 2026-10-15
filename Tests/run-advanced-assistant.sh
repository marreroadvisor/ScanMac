#!/bin/zsh
set -eu
cd "${0:A:h}/.."
stage=$(mktemp -d /private/tmp/scanmac-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr Source "$stage/Source"
python3 - "$stage/Main.swift" "$stage/Source/ScanMac.swift" <<'PY'
import sys
source=open(sys.argv[2]).read().split('@main struct ScanMacApp')[0]
open(sys.argv[1],'w').write(source)
PY
scanmacSources=("$stage/Source/"*.swift)
scanmacSources=("${(@)scanmacSources:#$stage/Source/ScanMac.swift}")
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" Tests/AdvancedAssistantHarness.swift -o "$stage/Skills" -target "$(uname -m)-apple-macos14.0" -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
mkdir -p "$1"
"$stage/Skills" "$1"
python3 Tests/check_layout_xml.py "$1"
