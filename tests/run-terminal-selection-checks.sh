#!/bin/zsh
# Link the Debug app's production terminal view and its bundled Ghostty engine.
set -euo pipefail
root="${0:A:h:h}"
derived="${1:?usage: tests/run-terminal-selection-checks.sh /path/to/DerivedData}"
derived="${derived:A}"
products="$derived/Build/Products/Debug"
app="$products/Kero Debug.app/Contents"
work="$(mktemp -d "${TMPDIR:-/tmp}/kero-selection-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
module_flags=()
for map in "$derived/Build/Intermediates.noindex/GeneratedModuleMaps"/TreeSitter*.modulemap; do
    module_flags+=(-Xcc "-fmodule-map-file=$map")
done
xcrun swiftc -parse-as-library \
    -I "$products" -I "$root/Vendor/alacritty-bridge/include" \
    -I "$root/Vendor/STTextView/Sources/STObjCLandShim/include" \
    -I "$root/Vendor/libghostty-spm/BinaryTarget/GhosttyKit.xcframework/macos-arm64_x86_64/Headers" \
    "${module_flags[@]}" -F "$products" "$app/MacOS/kero.debug.dylib" \
    -Xlinker -rpath -Xlinker "$app/MacOS" \
    -Xlinker -rpath -Xlinker "$app/Frameworks" \
    "$root/tests/TerminalSelectionChecks.swift" -o "$work/selection-checks"
"$work/selection-checks"
