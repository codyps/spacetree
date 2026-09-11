#!/bin/bash
# Executed only in the serialized, main-push publication job.
set -euo pipefail
: "${GH_REPO:?}"
: "${BUILD_SHA:?}"
: "${DISPLAY_VERSION:?}"
: "${BUILD_URL:?}"
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$DISPLAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+g[0-9a-f]{12,40}$ ]]
[[ "$BUILD_SHA" == "${DISPLAY_VERSION##*+g}"* ]]

# A slow older build must not replace the latest main build.
if [[ $(gh api "repos/$GH_REPO/commits/main" --jq .sha) != "$BUILD_SHA" ]]; then
    echo 'Skipping development publication: main has advanced.'
    exit 0
fi

dmg="SpaceTree-$DISPLAY_VERSION-universal.dmg"
test -s "$dmg"
test -s "$dmg.sha256"
shasum -a 256 --check "$dmg.sha256"
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<EOF
Development build from main: **$DISPLAY_VERSION**

Commit: $BUILD_SHA
Build: $BUILD_URL

This rolling prerelease is replaced by subsequent successful main builds.
Download the universal DMG and drag SpaceTree to Applications.
The app is ad-hoc signed and is not notarized.
EOF

# A missing release/tag is different from an API/authentication failure.
# Listing first lets unexpected API errors fail without masking them as 404s.
release_id=$(gh api --paginate "repos/$GH_REPO/releases" --jq '.[] | select(.tag_name == "development") | .id')
if [[ -z "$release_id" ]]; then
    gh release create development --target "$BUILD_SHA" --prerelease --latest=false --draft \
        --title 'Development build' --notes-file "$notes"
else
    [[ "$release_id" =~ ^[0-9]+$ ]]
fi
# Upload the new versioned pair first; retain the old pair if either upload fails.
gh release upload development "$dmg" "$dmg.sha256" --clobber

# Update the actual tag: release edit --target alone doesn't move an existing tag.
ref_sha=$(gh api --paginate "repos/$GH_REPO/git/matching-refs/tags/development" \
    --jq '.[] | select(.ref == "refs/tags/development") | .object.sha')
if [[ -n "$ref_sha" ]]; then
    gh api --method PATCH "repos/$GH_REPO/git/refs/tags/development" -f sha="$BUILD_SHA" -F force=true >/dev/null
else
    gh api --method POST "repos/$GH_REPO/git/refs" -f ref=refs/tags/development -f sha="$BUILD_SHA" >/dev/null
fi
gh release edit development --target "$BUILD_SHA" --prerelease --latest=false --draft=false \
    --title "Development build ($DISPLAY_VERSION)" --notes-file "$notes"

# Remove only obsolete assets owned by this workflow, after publication succeeds.
assets=$(gh release view development --json assets --jq '.assets[].name')
while IFS= read -r asset; do
    case "$asset" in
        SpaceTree-*-universal.dmg|SpaceTree-*-universal.dmg.sha256)
            if [[ "$asset" != "$dmg" && "$asset" != "$dmg.sha256" ]]; then
                gh release delete-asset development "$asset" --yes
            fi
            ;;
    esac
done <<< "$assets"
