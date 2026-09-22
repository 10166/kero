#!/bin/zsh

# Build a universal ad-hoc/self-signed preview package. Unlike the production
# release flow, this does not notarize or touch Sparkle/R2.
#
#   scripts/package-selfsigned.sh
#   OUTPUT_BASENAME=kero-0.1.49-preview scripts/package-selfsigned.sh

set -euo pipefail

cd "${0:A:h:h}"

identity="${CODE_SIGN_IDENTITY:--}"
archs="${ARCHS:-arm64 x86_64}"
build_dir="${KERO_PACKAGE_BUILD_DIR:-build/selfsigned}"
derived_data="$build_dir/DerivedData"
app="$derived_data/Build/Products/Release/Kero.app"

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print -u2 "missing required command: $1"
        exit 1
    fi
}

need xcodebuild
need codesign
need lipo
need plutil
need hdiutil
need shasum

rm -rf "$build_dir/dmg"
mkdir -p "$build_dir"

xcodebuild \
    -project Kero.xcodeproj \
    -scheme kero \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_USER_SCRIPT_SANDBOXING=NO \
    build

[[ -d "$app" ]] || { print -u2 "built app not found: $app"; exit 1; }

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
output_basename="${OUTPUT_BASENAME:-kero-$version-selfsigned}"
dmg="$build_dir/$output_basename.dmg"
sha="$build_dir/$output_basename.sha256"
staging="$build_dir/dmg"

rm -f "$dmg" "$sha"
mkdir -p "$staging"
ditto "$app" "$staging/Kero.app"
ln -s /Applications "$staging/Applications"

# The Rust daemon and bundled frameworks are nested code. Deep-sign the finished
# app here as a final packaging pass; a shallow outer signature can leave those
# helpers unsealed and make launch or strict verification fail.
timestamp_args=(--timestamp=none)
if [[ "$identity" != "-" ]]; then
    timestamp_args=(--timestamp)
fi

codesign --force --deep --sign "$identity" \
    --options runtime \
    --entitlements kero/kero.entitlements \
    "${timestamp_args[@]}" \
    --generate-entitlement-der \
    "$app"

# Keep this deep too: a shallow verify can pass even when nested code is stale
# or unsigned.
codesign --verify --deep --strict --verbose=2 "$app"
[[ "$(lipo -archs "$app/Contents/MacOS/kero")" == *arm64* ]] ||
    { print -u2 "expected an arm64 slice"; exit 1; }
[[ "$(lipo -archs "$app/Contents/MacOS/kero")" == *x86_64* ]] ||
    { print -u2 "expected an x86_64 slice"; exit 1; }

# hdiutil can briefly report the staging directory as busy while Spotlight or
# LaunchServices releases the freshly signed app. Retry instead of failing the
# otherwise-complete build.
created=false
for attempt in {1..3}; do
    rm -f "$dmg"
    if hdiutil create \
        -volname 'Kero Self-Signed Preview' \
        -srcfolder "$staging" \
        -ov \
        -format UDZO \
        "$dmg"
    then
        created=true
        break
    fi
    print "hdiutil create failed (attempt $attempt); retrying…"
    sleep 2
done
[[ "$created" == true ]] || { print -u2 'could not create DMG'; exit 1; }

codesign --force --sign "$identity" "${timestamp_args[@]}" "$dmg"
shasum -a 256 "$dmg" > "$sha"

hdiutil verify "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

print "Packaged Kero $version (build $build):"
print "  app : $app"
print "  dmg : $dmg"
print "  sha : $sha"
