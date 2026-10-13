#!/usr/bin/env bash
# Builds JJ.app into dist/.
#
#   ./build.sh            release build of dist/JJ.app
#   ./build.sh --run      build, then open the app
#   ./build.sh --debug    debug build (faster to compile, slower to run)
#   ./build.sh --test     run the test suite first
#
# Needs the Xcode command line tools (swift, sips, iconutil, codesign).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG=release
RUN=0
TEST=0
for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    --debug) CONFIG=debug ;;
    --test) TEST=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

if [[ $TEST == 1 ]]; then
  echo "▸ Testing"
  swift test
fi

echo "▸ Building ($CONFIG)"
swift build -c "$CONFIG" --product JJApp
swift build -c "$CONFIG" --product jj
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/dist/JJ.app"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/JJApp" "$APP/Contents/MacOS/JJ"
# Data files are looked up in the app's resources first.
for world in Earth Moon Mars; do
  cp -R "Sources/MyriaData/Resources/$world" "$APP/Contents/Resources/$world"
done

echo "▸ Drawing the icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN/jj" icon -o "$WORK/icon.png" --size 1024 >/dev/null
mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JJ</string>
  <key>CFBundleDisplayName</key><string>JJ</string>
  <key>CFBundleIdentifier</key><string>app.jj.myriahedral</string>
  <key>CFBundleExecutable</key><string>JJ</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>A homage to Jarke J. van Wijk's myriahedral projections. Data: Natural Earth, OpenStreetMap contributors (ODbL), PB2002, OpenFlights (ODbL), GPCP, NCEP/NCAR, ETOPO1.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "✓ Built $APP"

if [[ $RUN == 1 ]]; then
  open "$APP"
fi
