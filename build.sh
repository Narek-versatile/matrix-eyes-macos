#!/bin/bash
# Builds "Matrix Eyes.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Matrix Eyes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/MatrixEyes"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.metal "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md LICENSE "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Depth model (Apple's Depth Anything V2 Small, Core ML). Compiled once, then reused.
MODEL=Models/DepthAnythingV2SmallF16.mlpackage
[ -d "$MODEL" ] || ./scripts/fetch-model.sh || true
if [ -d "$MODEL" ]; then
    if [ ! -d build/DepthAnythingV2SmallF16.mlmodelc ] || [ "$MODEL" -nt build/DepthAnythingV2SmallF16.mlmodelc ]; then
        mkdir -p build
        xcrun coremlcompiler compile "$MODEL" build/ >/dev/null
    fi
    cp -R build/DepthAnythingV2SmallF16.mlmodelc "$APP/Contents/Resources/"
else
    echo "warning: $MODEL not found; the app will run without depth (flat mode)"
fi

# Ad-hoc signature so macOS can remember the camera permission.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
