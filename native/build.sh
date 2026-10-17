#!/bin/zsh
# 폰트 미리보기.app 빌드 — Xcode 없이 커맨드라인 툴(swiftc)만으로.
#   ./build.sh            → ../폰트 미리보기.app
set -e
HERE="${0:A:h}"
OUT="$HERE/../폰트 미리보기.app"
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path)"
BIN="$OUT/Contents/MacOS"
RES="$OUT/Contents/Resources"
# 빌드 번호: 빌드마다 1씩 증가 (native/BUILD_NUMBER)
VERSION="1.1"
AUTHOR="Hailey (haileydayz)"
CONTACT="hello@haileydayz.com"
BN_FILE="$HERE/BUILD_NUMBER"
BUILD=$(( $(cat "$BN_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD" > "$BN_FILE"
BUILT_AT="$(date +%Y-%m-%d)"
rm -rf "$OUT"
mkdir -p "$BIN" "$RES"

echo "▶ 컴파일 ($ARCH)…"
swiftc -O -parse-as-library \
  -target "$ARCH-apple-macos13.0" -sdk "$SDK" \
  -module-name FontViewer \
  "$HERE"/Sources/*.swift -o "$BIN/FontViewer"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleExecutable</key><string>FontViewer</string>
  <key>CFBundleIdentifier</key><string>com.haileydayz.fontviewer</string>
  <key>CFBundleName</key><string>폰트 미리보기</string>
  <key>CFBundleDisplayName</key><string>폰트 미리보기</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 $AUTHOR · 빌드 $BUILD ($BUILT_AT) · 문의 $CONTACT</string>
  <key>FVAuthor</key><string>$AUTHOR</string>
  <key>FVContact</key><string>$CONTACT</string>
  <key>FVBuiltAt</key><string>$BUILT_AT</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>폰트 폴더 또는 파일</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.font</string></array>
  </dict></array>
</dict></plist>
PLIST
echo -n 'APPL????' > "$OUT/Contents/PkgInfo"
[ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"
cp "$HERE/catalog.json" "$RES/catalog.json"
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "✅ $OUT  (v$VERSION 빌드 $BUILD, $BUILT_AT)"
