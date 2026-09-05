#!/bin/zsh
# Run after a Debug build. Tests link the exact Ghostty binary used by the app.
set -euo pipefail
root="${0:A:h:h}"
derived="${1:?usage: tests/run-remote-checks.sh /path/to/DerivedData}"
products="${derived}/Build/Products/Debug"
ghostty="${derived}/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_arm64e_x86_64"
work="$(mktemp -d "${TMPDIR:-/tmp}/kero-remote-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cat "$root/kero/Remote/RemoteControlService.swift" "$root/tests/RemoteServiceChecks.swift" > "$work/RemoteControlService.swift"
swiftc -parse-as-library -I "$products" -I "$ghostty/Headers" -L "$ghostty" \
    -import-objc-header "$root/Vendor/alacritty-bridge/include/kero_alacritty.h" \
    -L "$products/alacritty-bridge" \
    "$work/RemoteControlService.swift" \
    "$root/kero/Remote/RemoteAPIClient.swift" "$root/kero/Remote/RemoteCrypto.swift" \
    "$root/kero/Remote/RemoteModels.swift" "$root/kero/Remote/RemoteTerminalStateCapture.swift" \
    "$root/kero/Remote/RemoteOutputFilter.swift" \
    "$root/tests/RemoteTerminalChecks.swift" \
    "$products/GhosttyTerminal.o" "$products/GhosttyKit.o" "$products/MSDisplayLink.o" \
    -lghostty -lkero_alacritty -framework Carbon -framework AppKit -framework Metal -lc++ \
    -o "$work/remote-checks"
"$work/remote-checks"
