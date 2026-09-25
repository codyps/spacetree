#!/bin/bash
# Build a universal macOS app and a verified, drag-to-Applications disk image.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
version=${VERSION:-$(cat version.txt)}
display_version=${DISPLAY_VERSION:-$version}
build_number=${BUILD_NUMBER:-1}
build_root=${SPACETREE_BUILD_ROOT:-"$repo_root/.build/dmg"}
output_dir=${SPACETREE_OUTPUT_DIR:-"$repo_root/dist"}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo 'VERSION must be X.Y.Z and BUILD_NUMBER must be numeric.' >&2
    exit 1
fi
if [[ ! "$display_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-dev\.[0-9]+\+g[0-9a-f]{12,40}(\.dirty)?)?$ ]]; then
    echo 'DISPLAY_VERSION must be X.Y.Z or X.Y.Z-dev.N+gHASH[.dirty].' >&2
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
# Preserve Sparkle's framework symlinks, helpers, signatures, and permissions.
sparkle_root="$build_root/arm64/artifacts/sparkle/Sparkle"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$app/Contents/Frameworks/Sparkle.framework"
lipo "$app/Contents/Frameworks/Sparkle.framework/Sparkle" -verify_arch arm64 x86_64
cp "$sparkle_root/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
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
    <key>SpaceTreeDisplayVersion</key><string>$display_version</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
python3 scripts/configure-updater.py "$app/Contents/Info.plist"
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

dmg="$output_dir/SpaceTree-$display_version-universal.dmg"
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
# Generate a signed feed from only this build, never stale files in dist/.
# Keep private keys on stdin; they must not appear in process arguments or logs.
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    mkdir "$work_dir/feed"
    cp "$dmg" "$work_dir/feed/"
    release_tag="v$version"
    if [[ "$display_version" == *-dev.* ]]; then
        release_tag=development
    fi
    feed_args=(--maximum-deltas 0 --maximum-versions 1
        --download-url-prefix "https://github.com/${GITHUB_REPOSITORY:-codyps/spacetree}/releases/download/$release_tag/")
    if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
        printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$sparkle_root/bin/generate_appcast" \
            --ed-key-file - "${feed_args[@]}" "$work_dir/feed"
    else
        "$sparkle_root/bin/generate_appcast" "${feed_args[@]}" "$work_dir/feed"
    fi
    test -s "$work_dir/feed/appcast.xml"
    swift scripts/verify-update.swift "$app/Contents/Info.plist" "$work_dir/feed/appcast.xml" "$dmg"
    cp "$work_dir/feed/appcast.xml" "$output_dir/appcast.xml"
else
    # A reused output directory must not publish an old signed feed.
    rm -f "$output_dir/appcast.xml"
fi
printf 'Created %s\n' "$dmg"
