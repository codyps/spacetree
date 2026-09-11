#!/bin/bash
# Build a universal macOS app and a verified, drag-to-Applications disk image.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
version=${VERSION:-$(cat version.txt)}
build_number=${BUILD_NUMBER:-1}
build_root=${SPACETREE_BUILD_ROOT:-"$repo_root/.build/dmg"}
output_dir=${SPACETREE_OUTPUT_DIR:-"$repo_root/dist"}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo 'VERSION must be X.Y.Z and BUILD_NUMBER must be numeric.' >&2
    exit 1
fi
mkdir -p "$build_root" "$output_dir"
build_root=$(cd "$build_root" && pwd)
output_dir=$(cd "$output_dir" && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/spacetree-dmg.XXXXXX")
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$work_dir/mounted" || return
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

binaries=()
for arch in arm64 x86_64; do
    # Explicit triples keep both slices at the package's macOS 14 minimum.
    build_args=(--configuration release --product SpaceTree --triple "$arch-apple-macosx14.0"
                --scratch-path "$build_root/$arch" --disable-sandbox)
    swift build "${build_args[@]}"
    bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
    binaries+=("$bin_dir/SpaceTree")
done

app="$work_dir/image/SpaceTree.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work_dir/AppIcon.iconset"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/SpaceTree"
chmod 755 "$app/Contents/MacOS/SpaceTree"
# Bundle.main loads the packaged PNG; SwiftPM's Bundle.module remains the CLI fallback.
cp Sources/SpaceTree/Resources/AppIcon.png "$app/Contents/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Sources/SpaceTree/Resources/AppIcon.png \
        --out "$work_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Sources/SpaceTree/Resources/AppIcon.png \
        --out "$work_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.codyps.SpaceTree</string>
    <key>CFBundleName</key><string>SpaceTree</string>
    <key>CFBundleDisplayName</key><string>SpaceTree</string>
    <key>CFBundleExecutable</key><string>SpaceTree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
lipo "$app/Contents/MacOS/SpaceTree" -verify_arch arm64 x86_64
ln -s /Applications "$work_dir/image/Applications"
cat > "$work_dir/image/Install.txt" <<'TXT'
Drag SpaceTree.app to Applications. Requires macOS 14 or newer.

This CI build is ad-hoc signed, not Developer ID signed or notarized.
macOS Gatekeeper may block its first launch. Only allow a build you trust.
For protected folders, grant SpaceTree Full Disk Access in System Settings.
TXT

dmg="$output_dir/SpaceTree-$version-universal.dmg"
hdiutil create -volname SpaceTree -srcfolder "$work_dir/image" -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
mkdir "$work_dir/mounted"
hdiutil attach "$dmg" -mountpoint "$work_dir/mounted" -readonly -nobrowse
mounted=true
codesign --verify --deep --strict --verbose=2 "$work_dir/mounted/SpaceTree.app"
lipo "$work_dir/mounted/SpaceTree.app/Contents/MacOS/SpaceTree" -verify_arch arm64 x86_64
cmp "$app/Contents/Info.plist" "$work_dir/mounted/SpaceTree.app/Contents/Info.plist"
cmp Sources/SpaceTree/Resources/AppIcon.png "$work_dir/mounted/SpaceTree.app/Contents/Resources/AppIcon.png"
[[ $(readlink "$work_dir/mounted/Applications") == /Applications ]]
hdiutil detach "$work_dir/mounted"
mounted=false
(cd "$output_dir" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
printf 'Created %s\n' "$dmg"
