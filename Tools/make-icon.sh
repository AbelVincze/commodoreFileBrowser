#!/bin/bash
# Regenerates the app icon set from app_icon.png in the project root.
#
# The asset catalog holds ten resized copies of that file, so editing the
# source alone changes nothing. The target's first build phase runs this
# script, so a build picks the new artwork up on its own; run it by hand only
# when you want the catalog updated without building.
#
# Three things this gets right that are easy to get wrong by hand:
#
#   * Every entry gets its own file, even where two entries are the same
#     pixel size (16x16@2x and 32x32 are both 32 px). Pointing two entries at
#     one shared file makes actool emit an icns with four representations
#     instead of ten, silently and without a warning.
#   * The source must stay transparent. macOS composes its own rounded plate
#     behind the artwork; a white background would be baked in as a white
#     square sitting on that plate.
#   * Every run rewrites all eleven files, even the ones whose bytes have not
#     changed. The build phase declares them as its outputs, and their
#     timestamps are what tell Xcode the phase is done and actool that the
#     catalog needs recompiling. Skipping the unchanged ones leaves outputs
#     older than the input, and then the phase reruns on every single build.
#
# Script phases build sandboxed here, which is why the phase declares all
# eleven paths: nothing outside its declared outputs is writable, and a `cp`
# into the catalog would come back "Operation not permitted".
set -e
cd "$(dirname "$0")/.."

SRC="app_icon.png"
SET="CommodoreFileBrowser/Assets.xcassets/AppIcon.appiconset"

[ -f "$SRC" ] || { echo "error: no $SRC in the project root" >&2; exit 1; }

read -r w h <<<"$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel/{printf "%s ", $2}')"
if [ "$w" != 1024 ] || [ "$h" != 1024 ]; then
    echo "warning: $SRC is ${w}x${h}, expected 1024x1024 — the 512@2x slot will be upscaled"
fi
if ! sips -g hasAlpha "$SRC" | grep -q "hasAlpha: yes"; then
    echo "warning: $SRC has no alpha channel; macOS expects the background to be transparent"
fi

gen() { sips -s format png -Z "$2" "$SRC" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png 16;      gen icon_16x16@2x.png 32
gen icon_32x32.png 32;      gen icon_32x32@2x.png 64
gen icon_128x128.png 128;   gen icon_128x128@2x.png 256
gen icon_256x256.png 256;   gen icon_256x256@2x.png 512
gen icon_512x512.png 512;   gen icon_512x512@2x.png 1024

cat > "$SET/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png",     "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",     "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",   "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",   "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",   "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

echo "wrote 10 images to $SET from $SRC"

# Run by hand the fresh timestamps above are enough on their own. Run from the
# build phase there is nothing to clear anyway, and the sandbox would refuse.
if [ -z "${XCODE_VERSION_ACTUAL:-}" ]; then
    rm -rf build/Intermediates/CommodoreFileBrowser.build/*/CommodoreFileBrowser.build/assetcatalog* 2>/dev/null || true
    echo "asset catalogue cache cleared — build again to see it"
fi
