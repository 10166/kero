# Contributing to Kero

For anything larger than a fix, open an issue first —
Kero says no to features that fit some other tool better, and it's kinder to find
that out before the work.

## Go/MyGo application

Install the Go version in `go.mod` and, on macOS, a Rust toolchain. Build the
Alacritty bridge before building or testing the app:

```sh
scripts/build-go-alacritty.sh
GOFLAGS=-mod=mod CGO_ENABLED=1 go run github.com/egoist/mygo/cmd/mygo dev
```

The `GOFLAGS` setting keeps Go's module mode separate from the retained Swift
project's `Vendor` directory on case-insensitive filesystems. MyGo defaults to
disabling cgo, so `CGO_ENABLED=1` is required to include Alacritty on macOS.
Run `GOFLAGS=-mod=mod go test ./...` after building the bridge. For a universal
macOS package, install the `aarch64-apple-darwin` and `x86_64-apple-darwin`
Rust targets and pass `--universal` to the bridge script.

## Legacy Swift application

## Setup and build

```bash
git clone --recurse-submodules https://github.com/egoist/kero.git
```

Already cloned? `git submodule update --init --recursive`. Bun is also needed for
`web/` and `scripts/`.

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. Building for a second architecture needs its target
installed too — `rustup target add x86_64-apple-darwin`.

Open `kero.xcodeproj` and run the `kero` scheme, or:

```bash
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if you only have Xcode beta.

A Debug build is `sh.kero.dev` and keeps its own state, so it can run beside an
installed Kero without clobbering it: settings go to
`~/.config/kero-dev/config.toml`, and the session snapshot, sidebar widths, and
Sparkle preferences live under the separate bundle id.

## Remote-control regression checks

After a Debug build on Apple Silicon, run `tests/run-remote-checks.sh /path/to/DerivedData`.
It exercises the production credential-refresh code with simulated relay failures
and replays snapshots through the bundled Ghostty emulator. The terminal checks
need an awake display to create their AppKit windows.

Run `cargo test --manifest-path Vendor/alacritty-bridge/Cargo.toml` for the
Alacritty bridge and `go test ./...` from `relay/` for the relay.

## Headless daemon development

SSH terminals use [`kero-daemon`](daemon/README.md); local terminals use direct
PTYs. Build the daemon's four checksum-manifested installer assets before a
Release build. The daemon README
also documents the pinned Ghostty source build required by both renderers.

Run `cargo test --locked --manifest-path daemon/Cargo.toml` for process and
filesystem checks, and add `-p kero-terminal-state` for parser/checkpoint tests.
Build `--example checkpoint_fixture` before the remote renderer checks.
`python3 tests/run-daemon-ssh-checks.py` uses an isolated localhost sshd, including
a native jump-host connection, without changing Remote Login or user SSH keys.
External SSH tests require an explicitly authorized target and matching asset.
`tests/run-daemon-resource-checks.py --help` describes the opt-in Linux churn
check: repeated native gateway connections, persistent shell identity, naturally
exiting shells, watcher teardown, and `/proc` FD/thread/RSS samples. It uses a
fresh private namespace and removes only its own daemon/state afterward.

The host-group model checks use synthetic workspace wake notifications and
mock connections; they do not replace actual sleep/wake or AppKit interaction:

```bash
xcrun swiftc -parse-as-library -framework AppKit -framework Combine \
  kero/Hosts/HostGroups.swift kero/Hosts/HostStore.swift \
  kero/Hosts/SheetPresenter.swift \
  tests/HostGroupsChecks.swift -o /tmp/KeroHostGroupsChecks
/tmp/KeroHostGroupsChecks
```

SSH connection failure and retry checks exercise the real connection state
machine until its bundled helper is intentionally unavailable:

```bash
xcrun swiftc -parse-as-library -framework AppKit -framework Combine \
  kero/Hosts/SSHHostConnection.swift kero/Hosts/SSHConnectionDetailsSheet.swift \
  kero/Hosts/HostGroups.swift kero/Hosts/HostStore.swift kero/Hosts/SSHConfiguration.swift \
  kero/Hosts/SheetPresenter.swift \
  tests/SSHConnectionChecks.swift -o /tmp/KeroSSHConnectionChecks
/tmp/KeroSSHConnectionChecks
```

For an ad-hoc/self-signed preview DMG, use the packaging script. It deep-signs
the app after the build so bundled frameworks and the Rust daemon helper are
sealed, then verifies both the app and DMG with strict, deep checks:

```bash
scripts/package-selfsigned.sh
```

Clipboard image checks use a private pasteboard and create a small PNG fixture
for manual SSH/Agent testing; they do not modify the system clipboard:

```bash
xcrun swiftc -parse-as-library -framework AppKit -framework ImageIO \
  -framework UniformTypeIdentifiers kero/Hosts/DaemonWire.swift \
  kero/Hosts/RemoteImagePaste.swift tests/RemoteImagePasteChecks.swift \
  -o /tmp/KeroRemoteImagePasteChecks
/tmp/KeroRemoteImagePasteChecks
```

## Terminal selection regression checks

After an Apple Silicon Debug build, run
`tests/run-terminal-selection-checks.sh /path/to/DerivedData` with an awake display.
It opens the production `KeroTerminalView` with the app's bundled Ghostty engine
and checks, in a mouse-reporting TUI, that:

- navigation keys follow application cursor mode;
- a second drag starts a new selection and mouse-up stops selecting;
- Shift-click extends a selection and Shift-double-click selects a word;
- plain clicks, double-clicks, clicks with finger jitter, and right-clicks reach
  the program;
- a click that only focuses a pane stays out of the program, while dragging from
  it still selects.

It does not access the system clipboard.

## Website and docs

The site is in [`web/`](web/README.md); user documentation is MDX under
`web/content/docs`. It is written for people using the app — anything that only
matters when you are building it belongs here instead.

## Localization

Kero’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.
