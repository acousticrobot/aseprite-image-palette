#!/bin/sh
# Packages the extension into dist/image-palette.aseprite-extension
set -e
cd "$(dirname "$0")"
mkdir -p dist
rm -f dist/image-palette.aseprite-extension
(cd extension && zip -q -r ../dist/image-palette.aseprite-extension .)
echo "Built dist/image-palette.aseprite-extension"
