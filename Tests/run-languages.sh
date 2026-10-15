#!/bin/zsh
set -eu
cd "${0:A:h}/.."
stage=$(mktemp -d /private/tmp/scanmac-language-tests.XXXXXX)
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr Source "$stage/Source"
python3 - "$stage/Main.swift" "$stage/Source/ScanMac.swift" <<'PY'
import sys
open(sys.argv[1],'w').write(open(sys.argv[2]).read().split('@main struct ScanMacApp')[0])
PY
scanmacSources=("$stage/Source/"*.swift)
scanmacSources=("${(@)scanmacSources:#$stage/Source/ScanMac.swift}")
scanmacFlags=(-target "$(uname -m)-apple-macos14.0" -parse-as-library -swift-version 5 -module-cache-path "$stage/module-cache" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security)
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" Tests/OCRLanguageHarness.swift -o "$stage/OCRRunner" "${scanmacFlags[@]}"
"$stage/OCRRunner"
if [[ "${1:-}" == "ocr-only" ]]; then exit 0; fi
python3 Tests/check_languages.py Resources/Languages
mkdir -p "$stage/Languages.app/Contents/MacOS"
ditto --norsrc --noextattr Resources "$stage/Languages.app/Contents/Resources"
cat > "$stage/Languages.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Languages</string><key>CFBundleIdentifier</key><string>local.scanmac.language-tests</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc "$stage/Main.swift" "${scanmacSources[@]}" Tests/LanguageHarness.swift -o "$stage/Languages.app/Contents/MacOS/Languages" "${scanmacFlags[@]}"
"$stage/Languages.app/Contents/MacOS/Languages" "$stage/Languages.app/Contents/Resources/Languages"
