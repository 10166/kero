#!/bin/bash
# Build a pinned headless server asset; never install, start, publish or replace it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-aarch64-apple-darwin}"
case "$target" in
  aarch64-apple-darwin|x86_64-apple-darwin|aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) ;;
  *) echo "unsupported daemon target: $target" >&2; exit 2 ;;
esac
cargo_bin="${CARGO:-$HOME/.cargo/bin/cargo}"
if [[ "$target" == *linux* && "$(uname -s)" == Darwin ]]; then
  "$cargo_bin" zigbuild --locked --release --manifest-path "$root/daemon/Cargo.toml" --target "$target"
else
  "$cargo_bin" build --locked --release --manifest-path "$root/daemon/Cargo.toml" --target "$target"
fi
output="$root/build/daemon"
mkdir -p "$output"
artifact="$output/kero-daemon-$target"
cp "$root/daemon/target/$target/release/kero-daemon" "$artifact"
chmod 755 "$artifact"
python3 - "$artifact" "$target" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = {"product": "kero-daemon", "protocol": 1, "target": sys.argv[2], "asset": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
path.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest))
PY
