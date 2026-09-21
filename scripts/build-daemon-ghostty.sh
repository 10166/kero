#!/bin/bash
# The daemon renderer must suppress terminal-generated replies. The upstream
# binary does not contain that patch; build this pinned source for both slices.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/prepare-daemon-ghostty.sh"
revision="$(cat "$root/Vendor/libghostty-spm/Ghostty.ref" | tr -d '\n')"
cache="$root/build/daemon-ghostty"
mkdir -p "$cache"
archive="$cache/source.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl -fL --retry 3 "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$revision" -o "$archive"
fi
python3 - "$archive" "$cache" "$revision" <<'PY'
import hashlib,pathlib,sys,tarfile,shutil
archive=pathlib.Path(sys.argv[1]);destination=pathlib.Path(sys.argv[2]).resolve()
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='057c6c2a8851bef9d80a6c628124fbcfeb12876fc72c31c67a9c1ecde56f999e','Ghostty source checksum mismatch'
source=destination/('ghostty-'+sys.argv[3])
if source.exists(): shutil.rmtree(source)
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        path=(destination/member.name).resolve()
        assert path==destination or destination in path.parents,'Unsafe archive path'
    tar.extractall(destination)
PY
# git apply is required for the binary framedata patch; BSD patch silently
# skips that payload in a source archive without a Git directory.
git init --quiet "$cache/ghostty-$revision"
export KERO_METAL_DEVELOPER_DIR="${KERO_METAL_DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -n "${KERO_ZIG_DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="$KERO_ZIG_DEVELOPER_DIR"
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
for architecture in aarch64 x86_64; do
  "$root/Vendor/libghostty-spm/Script/build-ghostty.sh" "$cache/ghostty-$revision" "$architecture-macos" "$cache/$architecture"
done
mkdir -p "$cache/universal"
lipo -create "$cache/aarch64/lib/libghostty.a" "$cache/x86_64/lib/libghostty.a" -output "$cache/universal/libghostty.a"
output="$root/Vendor/libghostty-spm/BinaryTarget/GhosttyKit.xcframework"
rm -rf "$output"
env DEVELOPER_DIR="$KERO_METAL_DEVELOPER_DIR" xcodebuild -create-xcframework -library "$cache/universal/libghostty.a" -headers "$cache/aarch64/include" -output "$output"
