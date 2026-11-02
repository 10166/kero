#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root/engine/alacritty/bridge/Cargo.toml"

if [ "${1:-}" = "--universal" ]; then
    cargo build --release --locked --manifest-path "$manifest" --target aarch64-apple-darwin
    cargo build --release --locked --manifest-path "$manifest" --target x86_64-apple-darwin
    target="$root/engine/alacritty/bridge/target"
    mkdir -p "$target/release"
    lipo -create "$target/aarch64-apple-darwin/release/libkero_alacritty.a" \
        "$target/x86_64-apple-darwin/release/libkero_alacritty.a" \
        -output "$target/release/libkero_alacritty.a"
else
    cargo build --release --locked --manifest-path "$manifest"
fi
