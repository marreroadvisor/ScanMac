#!/bin/zsh
set -eu
cd "${0:A:h}/.."
stage=$(mktemp -d /private/tmp/scanmac-library-test.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr Source "$stage/Source"
python3 - "$stage/Main.swift" "$stage/Source/ScanMac.swift" <<'PY'
import sys
source=open(sys.argv[2]).read().split('@main struct ScanMacApp')[0]
open(sys.argv[1],'w').write(source)
PY
xcrun swift -module-cache-path "$stage/cache" Tests/Fixture.swift "$stage/fixture.pdf"
scanmacSources=("$stage/Source/"*.swift)
scanmacSources=("${(@)scanmacSources:#$stage/Source/ScanMac.swift}")
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" Tests/LibraryHarness.swift -o "$stage/Tools" -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 -module-cache-path "$stage/cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security -framework WebKit
"$stage/Tools" "$stage/fixture.pdf"
