#!/bin/bash
# Builds the app and packages it for a GitHub release:
#   dist/Matrix-Eyes.zip and dist/Matrix-Eyes.zip.sha256
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
[ -d "Matrix Eyes.app/Contents/Resources/DepthAnythingV2SmallF16.mlmodelc" ] \
    || { echo "The depth model is missing from the build; run scripts/fetch-model.sh" >&2; exit 1; }

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent "Matrix Eyes.app" dist/Matrix-Eyes.zip
(cd dist && shasum -a 256 Matrix-Eyes.zip > Matrix-Eyes.zip.sha256)
cat dist/Matrix-Eyes.zip.sha256
ls -lh dist
