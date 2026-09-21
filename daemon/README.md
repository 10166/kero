# Kero persistent sessions

Kero's local and SSH terminals use `kero-daemon` to own their PTYs. Ghostty and
Alacritty are renderer-only clients. Closing a window, quitting the app,
collapsing a host group, or losing a connection detaches the client. Explicitly
closing a connected terminal or project ends its shell after daemon confirmation.

The AppKit sidebar groups local projects, SSH hosts, and existing relay devices.
Only expanded groups connect, subscribe, and retry. Collapsed selections display
a disconnected placeholder. SSH authentication and host-key prompts use AppKit;
optional saved secrets use Keychain. The existing relay authentication,
end-to-end encryption, single-controller lease, and reclaim flow are retained.

## Restoration

A live daemon restores the same process, environment, directory, jobs, and
terminal state. Host, daemon-instance, session, project, tab and pane identities
are persisted. A daemon restart changes its instance ID: old references cannot
attach to another process. Reopening then starts a new login shell, restores
bounded primary history and directory, and shows a new-shell notice. Previous
task commands are never re-executed. Legacy layouts remain readable.

The authoritative terminal parser lives in `terminal-state/`. Attach takes a
checkpoint under the same lock as PTY parsing and byte sequencing. It encodes
primary/alternate screens, history, cursor/saved cursor, wrap state, colors,
character sets, modes, keyboard stacks, title stacks, and incomplete parser
state. Renderers suppress protocol replies; the daemon answers queries even
without a GUI. Checkpoints do not execute clipboard, notification or URL actions.
Renderer-side filtering rejects remote Kitty file/path transfers.

Canonical checkpoints also preserve bounded inline Kitty images, placements on
both screens, scrollback anchors, and unfinished chunked uploads. The daemon
answers image queries and follows the [Kitty protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
for final-chunk cursor placement. Each session limits stored image data to 8 MiB
and image placements to 16,384. File/shared-memory transfers, image animation,
Unicode image placeholders and relative image placements are not supported by
the shared graphics implementation.

## Remote projects and installation

`HostService` binds every file and Git operation to an expanded host capability
and a daemon host UUID. Files support create/read/save/rename/remove and directory
watching. Saves compare SHA-256 before atomic replacement; dirty editors survive
disconnection, window close and app restart. Git status, stage, commit, branches
and diffs use the same host service. No uncertain write or Git operation is
repeated automatically. Save serialization protects Kero writers, but is not a
filesystem transaction against an unrelated external writer racing final rename.

Native SSH uses the pinned tty7/russh engine, including jump hosts and host-key
verification at each hop. OpenSSH `ssh -G` only resolves configuration; it is not
the transport. Unsupported proxy commands, forwarding/certificate settings and
algorithm allow-lists with no supported intersection are reported. Supported
algorithms retain the configured order; no unconfigured fallback is added. Installer assets cover macOS/Linux, arm64 and
x86_64. Uploads are checksum checked and content addressed in the user's directory.
No root, desktop service or public listening port is required. A running compatible
daemon is reused; an incompatible one fails without ending its sessions.
Reconnecting checks the content-addressed executable's checksum and protocol
before uploading. A cache hit does not upload or show Installing. Starting a
connection probes the existing daemon before spawning a replacement.
If the daemon exits while SSH remains connected, a fresh channel ensures the
service is running before attaching. Restarting the service does not recreate
a shell or repeat a file/Git request; the GUI separately restores a new shell
and identifies it as such.

State defaults to `~/.local/state/kero/daemon-v1` (`kero-dev` for Debug).
The directory is 0700, socket/state files are private, and a lifetime lock prevents
an upgrade from unlinking an active daemon socket. Test builds can supply explicit
local and remote state namespaces in their bundle metadata.

## Clipboard images over SSH

Copying selected remote terminal text uses the macOS clipboard normally.
For SSH terminals, explicit Command-V or Control-V with a clipboard image (or
one copied image file) converts it to PNG and uploads it to that session's
private remote attachment directory. After SHA-256 verification, Kero pastes the
quoted remote path using the daemon's authoritative bracketed-paste mode.
Claude Code and Codex can recognize that path as an image attachment. No Enter
key or model request is generated. Both Ghostty and Alacritty use this transport.
Relay image upload is not implemented by this SSH-specific path.

Uploads are limited to one per GUI at a time, 4 MiB per encoded image, 64 MiB/256
files per session, and 256 MiB/4,096 files per daemon. Decoding is bounded to
32 MiB source data and 40 megapixels. Files are mode 0600 beneath the private
daemon directory. Explicit session termination removes attachments; natural
shell exit removes them after the last subscriber detaches. Uploads sweep files
older than seven days. Recent attachments are never evicted merely to make room.
Disconnecting preserves attachments and tasks. Failed or uncertain uploads are
not retried, and a late result cannot paste into a disconnected/replaced session.
An older running daemon without the image capability remains alive and reports
that it needs a restart after its active sessions finish.

## Build and verify

```sh
cargo test --locked --manifest-path daemon/Cargo.toml
cargo test --locked --manifest-path daemon/Cargo.toml -p kero-terminal-state
cargo build --locked --manifest-path daemon/Cargo.toml --example checkpoint_fixture
python3 tests/run-daemon-ssh-checks.py
scripts/build-daemon.sh aarch64-apple-darwin
scripts/build-daemon.sh x86_64-apple-darwin
scripts/build-daemon.sh aarch64-unknown-linux-musl
scripts/build-daemon.sh x86_64-unknown-linux-musl
```

Linux cross-builds on macOS require `cargo-zigbuild`, Zig, and the matching Rust
standard-library targets. Assets and SHA-256 manifests are written to
`build/daemon/`. Release builds require all four verified assets. Nothing is
published by these scripts.

The Ghostty fork is reproducible from the existing submodule pin plus
`patches/libghostty-daemon.patch`:

```sh
scripts/prepare-daemon-ghostty.sh
scripts/build-daemon-ghostty.sh
```

Use Zig 0.15.2 for Ghostty. On Xcode 27, setting `KERO_ZIG_DEVELOPER_DIR` to the
installed Command Line Tools directory permits its compatible SDK while
`KERO_METAL_DEVELOPER_DIR` selects Xcode's Metal toolchain. The script downloads
only the fixed, checksum-verified source archive, then builds both macOS slices.
After a Debug app build, run `tests/run-remote-checks.sh /path/to/DerivedData`.
This exercises canonical snapshots in the exact Ghostty and Alacritty libraries.

The localhost SSH fixture creates temporary keys and an isolated sshd. It does
not alter Remote Login or user known-hosts files. For an explicitly authorized
external test host, set `KERO_EXTERNAL_SSH_SPEC` to a private JSON NativeSshSpec and
`KERO_EXTERNAL_DAEMON` to its matching asset, then run the ignored
`external_host_install_files_git_checkpoint_and_reconnect` test. It verifies
existing known-host trust, installs an immutable asset, and removes only its
UUID-named temporary state/repository after testing.

## Protocol and bounds

Frames are little-endian u32 length, u8 kind, payload (maximum 8 MiB). Kind 1 is
JSON control; kind 2 is an ending u64 offset and unchanged PTY bytes; kind 3 is
input; kind 4 is an offset, final-chunk flag and checkpoint bytes. Hello negotiates
version and capabilities. Every session operation carries host/instance/session
UUIDs. Terminal subscriptions and directory watches have dedicated connections.
Relay bootstrap uses an ordered checkpoint barrier on the existing attachment.

PTY subscriber queues are bounded (64 × 16 KiB); slow clients disconnect while
background output continues. Input is bounded by 2 MiB of queued bytes (64 KiB per frame), coalescing key frames, history by 500,000
cells/10,000 lines, checkpoints by 32 MiB, sessions by 256, and clients by 64.
Editor reads are limited to 4 MiB; directory listings to 50,000 entries; Git stdout
and stderr to 4 MiB/256 KiB with a 60-second execution bound.

See [verification evidence](validation/2026-09-21-macos.md) for measured checks and
remaining hardware/manual coverage. Upstream Apache-2.0 licensing and attribution
are retained in [tty7 provenance](../Vendor/tty7-core/KERO-VENDOR.md).
