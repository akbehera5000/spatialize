#!/bin/zsh
# Builds Spatialize.app: the SwiftUI app plus the whole conversion engine inside it.
# Run ../build.sh first so the engine tools exist. Output: ../Spatialize.app
set -euo pipefail
ROOT=${0:A:h:h}
cd ${0:A:h}
APP=$ROOT/Spatialize.app
ENGINE=$APP/Contents/Resources/engine

swift build -c release
rm -rf $APP
mkdir -p $APP/Contents/MacOS $ENGINE/bin
cp .build/release/Spatialize $APP/Contents/MacOS/

# engine
cp $ROOT/atmos2apple $ROOT/speaker-test $ROOT/music2spatial $ROOT/tools/separate.py $ENGINE/
for t in atmos-render spatial-post walkgen stem-render apacenc mux vtcheck pgs2srt synccheck binaural; do cp $ROOT/bin/$t $ENGINE/bin/; done
cp $ROOT/vendor/truehdd/target/release/truehdd $ENGINE/bin/
cp $ROOT/vendor/OpenJOC/target/release/openjoc $ENGINE/bin/
for t in ffmpeg ffprobe; do cp "$(command -v $t)" $ENGINE/bin/; done
# uv installs the song separation engine (Demucs) on first use (MIT/Apache-2.0, astral.sh)
UV=$(command -v uv || print ~/.local/bin/uv); [[ -x $UV ]] && cp $UV $ENGINE/bin/uv
# a generic measured head for the live player's SOFA renderer (MIT KEMAR, public domain data)
mkdir -p $ENGINE/hrtf
cp $ROOT/vendor/libmysofa/share/MIT_KEMAR_normal_pinna.sofa $ENGINE/hrtf/KEMAR.sofa

# Shortcuts actions (App Intents): Xcode normally extracts their metadata; do the same here
CONSTS=$(mktemp) SRCS=$(mktemp)
find .build -name '*.swiftconstvalues' -path '*Spatialize*' -newer Package.swift > $CONSTS
ls $PWD/Sources/Spatialize/*.swift > $SRCS
xcrun appintentsmetadataprocessor --output $APP/Contents/Resources \
  --toolchain-dir "$(dirname $(dirname $(dirname $(xcrun --find swiftc))))" --module-name Spatialize \
  --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
  --source-file-list $SRCS --swift-const-vals-list $CONSTS >/dev/null 2>&1 \
  || print "note: Shortcuts metadata not generated"
rm -f $CONSTS $SRCS

# icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p $ICONSET
swift make-icon.swift $ICONSET/icon_512x512@2x.png
for s in 16 32 128 256 512; do
  sips -z $s $s $ICONSET/icon_512x512@2x.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $ICONSET/icon_512x512@2x.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spatialize</string>
  <key>CFBundleDisplayName</key><string>Spatialize</string>
  <key>CFBundleIdentifier</key><string>local.spatialize.app</string>
  <key>CFBundleExecutable</key><string>Spatialize</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMotionUsageDescription</key><string>Spatialize uses your AirPods' motion sensors so the live player can keep sounds in place when you turn your head.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convert with Spatialize</string></dict>
      <key>NSMessage</key><string>convertMovies</string>
      <key>NSPortName</key><string>Spatialize</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.audiovisual-content</string>
        <string>org.matroska.mkv</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.matroska.mkv</string>
      <key>UTTypeDescription</key><string>Matroska Video</string>
      <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>mkv</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Movie</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>org.matroska.mkv</string>
        <string>public.movie</string>
        <string>public.audiovisual-content</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array><string>mkv</string><string>mka</string><string>mp4</string><string>m2ts</string><string>ts</string><string>mov</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Song</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.audio</string></array>
      <key>CFBundleTypeExtensions</key>
      <array><string>mp3</string><string>m4a</string><string>flac</string><string>wav</string><string>aiff</string><string>aif</string><string>ogg</string><string>opus</string><string>alac</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - $APP >/dev/null 2>&1 || true
# let macOS see the Finder service and the Shortcuts actions straight away
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
print "built $APP"
