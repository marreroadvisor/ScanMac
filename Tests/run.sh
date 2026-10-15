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
xcrun swift -module-cache-path "$stage/module-cache" Tests/Fixture.swift "$stage/fixture.pdf"
scanmacSources=("$stage/Source/"*.swift)
scanmacSources=("${(@)scanmacSources:#$stage/Source/ScanMac.swift}")
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" Tests/Integration.swift -o "$stage/Integration" -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
"$stage/Integration" "$stage/fixture.pdf"

cp Tests/ImageStamps.swift "$stage/StampHarness.swift"
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" "$stage/StampHarness.swift" -o "$stage/Stamps" -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
"$stage/Stamps"
cp Tests/LayoutConversion.swift "$stage/LayoutHarness.swift"
mkdir -p "$stage/layout"
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" "$stage/LayoutHarness.swift" -o "$stage/LayoutRunner" -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
"$stage/LayoutRunner" "$stage/layout"
python3 Tests/check_layout_xml.py "$stage/layout"

cp Tests/InkResizeHarness.swift "$stage/InkHarness.swift"
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" "$stage/InkHarness.swift" -o "$stage/InkRunner" -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
"$stage/InkRunner"
xcrun swiftc Source/LocalNetworking.swift Tests/LocalNetworkHarness.swift -o "$stage/NetworkRunner" -parse-as-library
python3 Tests/check_redirect.py "$stage/NetworkRunner"
