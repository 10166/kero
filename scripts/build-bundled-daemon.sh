#!/bin/zsh
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd "$SRCROOT"
profile=release
if [[ "$CONFIGURATION" == Debug ]]; then profile=debug; fi
args=(--locked --manifest-path daemon/Cargo.toml)
if [[ "$profile" == release ]]; then args+=(--release); fi
binaries=()
for architecture in ${=ARCHS}; do
    case "$architecture" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) print -u2 "Unsupported daemon architecture: $architecture"; exit 1 ;;
    esac
    cargo build "${args[@]}" --target "$target"
    binaries+=("$SRCROOT/daemon/target/$target/$profile/kero-daemon")
done
mkdir -p "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
lipo -create "${binaries[@]}" -output "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/kero-daemon"

# The app signing phase sees this copied helper as nested code and fails when
# the Rust build phase leaves it unsigned.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --options runtime \
        --timestamp=none --generate-entitlement-der \
        "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/kero-daemon"
fi

if [[ "$CONFIGURATION" == Release ]]; then
    python3 - "$SRCROOT/build/daemon" <<'PYASSETS'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
for target in ['aarch64-apple-darwin','x86_64-apple-darwin','aarch64-unknown-linux-musl','x86_64-unknown-linux-musl']:
    asset=root/('kero-daemon-'+target)
    manifest=json.loads(asset.with_suffix('.json').read_text())
    assert manifest['target']==target and manifest['asset']==asset.name and manifest['protocol']==1
    assert hashlib.sha256(asset.read_bytes()).hexdigest()==manifest['sha256'], f'Invalid daemon asset: {target}'
PYASSETS
fi

# These are immutable, checksum-manifested server assets, independent of the
# GUI architecture. Building an installer never downloads executable code.
if [[ -d "$SRCROOT/build/daemon" ]]; then
    mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/daemon"
    rsync -a "$SRCROOT/build/daemon/" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/daemon/"
fi
