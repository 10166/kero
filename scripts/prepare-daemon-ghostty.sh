#!/bin/bash
# Keep the existing submodule pin; all Kero changes live in this repository.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/Vendor/libghostty-spm"
patch="$root/patches/libghostty-daemon.patch"
if git -C "$source" apply --reverse --check "$patch" >/dev/null 2>&1; then exit 0; fi
git -C "$source" apply --check "$patch"
git -C "$source" apply "$patch"
