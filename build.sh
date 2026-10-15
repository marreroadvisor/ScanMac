#!/bin/zsh
set -eu
cd "${0:A:h}"
python3 Tests/check_languages.py Resources/Languages
stage=$(mktemp -d /private/tmp/scanmac-build.XXXXXX)
trap 'rm -rf "$stage"' EXIT
scanmacCache="$stage/module-cache"
mkdir -p "$scanmacCache" "$stage/ScanMac.app/Contents/MacOS" "$stage/ScanMac.app/Contents/Resources"
ditto --norsrc --noextattr Source "$stage/Source"
if [[ -d Resources ]]; then ditto --norsrc --noextattr Resources "$stage/ScanMac.app/Contents/Resources"; fi
for scanmacArchitecture in arm64 x86_64; do
  xcrun swiftc "$stage/Source/"*.swift -target "${scanmacArchitecture}-apple-macos14.0" -o "$stage/ScanMac-${scanmacArchitecture}" -parse-as-library -swift-version 5 -O -module-cache-path "$scanmacCache/$scanmacArchitecture" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework CoreText -framework AVFoundation -framework QuartzCore -framework Quartz -framework ImageCaptureCore -framework Security
done
lipo -create "$stage/ScanMac-arm64" "$stage/ScanMac-x86_64" -output "$stage/ScanMac.app/Contents/MacOS/ScanMac"
if [[ -d Engines ]]; then ditto --norsrc --noextattr Engines "$stage/ScanMac.app/Contents/Resources/Engines"; fi
if [[ -f Assets/AppIcon.icns ]]; then cp Assets/AppIcon.icns "$stage/ScanMac.app/Contents/Resources/SMIcon.icns"; fi
if [[ -f Server/server.py ]]; then mkdir -p "$stage/ScanMac.app/Contents/Resources/Server"; cp Server/server.py "$stage/ScanMac.app/Contents/Resources/Server/server.py"; fi
cat > "$stage/ScanMac.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScanMac</string>
<key>CFBundleIdentifier</key><string>local.scanmac.desktop</string>
<key>CFBundleIconFile</key><string>SMIcon</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundleName</key><string>ScanMac</string>
<key>CFBundleDisplayName</key><string>ScanMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key><string>ScanMac busca escáneres Bonjour solo cuando solicitas buscar dispositivos.</string>
<key>NSBonjourServices</key><array><string>_scanner._tcp</string><string>_uscan._tcp</string><string>_uscans._tcp</string></array>
<key>NSCameraUsageDescription</key><string>ScanMac usa la cámara solo al iniciar una captura de documentos.</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Documents</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>public.png</string><string>public.jpeg</string></array></dict></array>
</dict></plist>
PLIST
python3 - "$stage/ScanMac.app/Contents" <<'PYRES'
import json, pathlib, plistlib, sys
contents = pathlib.Path(sys.argv[1]); resources = contents / 'Resources'
languages = json.loads((resources / 'Languages/languages.json').read_text())
p = contents / 'Info.plist'
info = plistlib.loads(p.read_bytes()); info['CFBundleDevelopmentRegion'] = 'en'; info['CFBundleLocalizations'] = [r[0] for r in languages]
p.write_bytes(plistlib.dumps(info))
for code, _, _ in languages:
    values = json.loads((resources / 'Languages' / (code + '.json')).read_text())
    localized = resources / (code + '.lproj'); localized.mkdir(exist_ok=True)
    (localized / 'Localizable.strings').write_text('/* UI catalog: ../Languages/' + code + '.json */\n')
    usage = {'NSCameraUsageDescription': values['ScanMac uses the camera only when you start a document capture.'], 'NSLocalNetworkUsageDescription': values['ScanMac looks for Bonjour scanners only when you request device discovery.']}
    (localized / 'InfoPlist.strings').write_text('\n'.join(json.dumps(k, ensure_ascii=False) + ' = ' + json.dumps(v, ensure_ascii=False) + ';' for k, v in usage.items()) + '\n')
PYRES
cp LICENSE "$stage/ScanMac.app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$stage/ScanMac.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --deep --sign - "$stage/ScanMac.app"
codesign --verify --deep --strict "$stage/ScanMac.app"
ditto -c -k --norsrc --noextattr --keepParent "$stage/ScanMac.app" "$stage/ScanMac.zip"
if [[ -d ScanMac.app ]]; then mv ScanMac.app "$stage/Previous-ScanMac.app"; fi
if ! ditto --norsrc --noextattr "$stage/ScanMac.app" ScanMac.app; then
  if [[ -d "$stage/Previous-ScanMac.app" ]]; then ditto --norsrc --noextattr "$stage/Previous-ScanMac.app" ScanMac.app; fi
  exit 1
fi
# Some Documents File Providers attach empty FinderInfo to new bundles.
# Remove only this display attribute; preserve File Provider metadata.
if xattr -p com.apple.FinderInfo ScanMac.app >/dev/null 2>&1; then xattr -d com.apple.FinderInfo ScanMac.app || true; fi
# The File Provider can reattach FinderInfo later; the verified clean ZIP is authoritative.
mv "$stage/ScanMac.zip" ScanMac.zip
