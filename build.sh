#!/bin/zsh
# Builds everything atmos2apple needs. Requires Homebrew; installs Rust and ffmpeg if missing.
set -euo pipefail
setopt extended_glob
cd ${0:A:h}

command -v cargo >/dev/null || brew install rust
command -v ffmpeg >/dev/null || brew install ffmpeg

mkdir -p vendor bin
[[ -d vendor/truehdd ]] || git clone --depth 1 https://github.com/truehdd/truehdd.git vendor/truehdd
[[ -d vendor/OpenJOC ]] || git clone --depth 1 https://github.com/chyinan/OpenJOC.git vendor/OpenJOC

(cd vendor/truehdd && cargo build --release)
(cd vendor/OpenJOC && cargo build --release -p openjoc-cli)
(cd tools/atmos-render && cargo build --release) \
  && cp tools/atmos-render/target/release/{atmos-render,spatial-post,walkgen} bin/
swiftc -O tools/probe.swift -o bin/probe
swiftc -O tools/apacenc.swift -o bin/apacenc
swiftc -O tools/mux.swift -o bin/mux
swiftc -O tools/pgs2srt.swift -o bin/pgs2srt
swiftc -O tools/synccheck.swift -o bin/synccheck
swiftc -O tools/vtcheck.swift -o bin/vtcheck
# binaural renderer: needs libmysofa (the app's copy) for SOFA head models
SOFA=app/Sources/CMySofa OBJ=$(mktemp -d)
for c in $SOFA/sofa_bridge.c $SOFA/mysofa/**/*.c; do
  clang -O2 -w -c -DFLOATING_POINT -DOUTSIDE_SPEEX -DRANDOM_PREFIX=mysofa -DEXPORT= \
    -I$SOFA/include -I$SOFA/mysofa -I$SOFA/mysofa/hrtf -I$SOFA/mysofa/resampler $c -o $OBJ/${${c//\//_}%.c}.o
done
swiftc -O -import-objc-header $SOFA/include/sofa_bridge.h tools/binaural/main.swift app/Sources/Spatialize/HRIRSet.swift \
  $OBJ/*.o -lz -o bin/binaural
rm -rf $OBJ
echo "build complete"
