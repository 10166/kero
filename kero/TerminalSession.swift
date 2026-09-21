//
//  TerminalSession.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; a CLI-created project can instead
/// exec an explicit argv directly. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and split-layout changes.
///
/// Which emulator draws that surface is `TerminalBackend`'s business: this
/// type talks to ``TerminalBackendSurface`` and hears back through
/// ``TerminalBackendEvents``, and names no emulator's types itself.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id: UUID
    nonisolated let hostID: UUID

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false
    @Published private(set) var connectionState = DaemonTerminalTransport.State.disconnected
    @Published private(set) var restoredAsNewShell = false
    let transport: DaemonTerminalTransport
    var daemonIdentity: DaemonSessionIdentity? { transport.identity }
    var isConnected: Bool { connectionState == .connected }
    @Published private(set) var commandLifecycle = TerminalCommandLifecycle()
    @Published private(set) var terminalCellSize: CGSize?
    @Published private(set) var isRemotelyControlled = false
    /// Recognized coding agent occupying this terminal, if any. The monitor
    /// reconciles foreground process identity with explicit lifecycle events.
    @Published var agentStatus: KeroAgentStatus?

    /// The emulator driving this session. Fixed for the session's lifetime —
    /// changing the setting only affects terminals opened afterwards.
    let backend: TerminalBackend
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    private let connectionView = SessionConnectionView(frame: .zero)
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private var cachedShellPid: pid_t?
    private var lastHistorySnapshot: String?
    private var isTerminating = false
    private var imagePasteTask: Task<Void, Never>?
    private let imagePasteIndicator = NSProgressIndicator()
    private var remoteOutputHandler: ((Data) -> Void)?
    private var commandExecutionStartedAtNanos: UInt64?
    /// Alternate-screen transcript paging must begin at the live prompt, never
    /// from text the user has scrolled back to inspect.
    var terminalIsAtLiveBottom = true
    let agentObservation = KeroAgentObservationState()

    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil,
        persistentID: UUID? = nil,
        daemonIdentity: DaemonSessionIdentity? = nil,
        hostID: UUID = HostGroups.localID
    ) {
        let sessionID = persistentID ?? UUID()
        let directCommand = commandArguments.flatMap { $0.isEmpty ? nil : $0 }
        let shellPath = directCommand?.first ?? Self.loginShell()
        let directory = hostID == HostGroups.localID ? Self.validWorkingDirectory(initialDirectory) : (initialDirectory ?? HostGroups.shared.definition(hostID)?.directory ?? "")
        let artifacts = Self.makeLaunchArtifacts()
        let backend = AppSettings.shared.terminalBackend
        let script = Self.makeLaunchScript(
            backend: backend,
            shellPath: shellPath,
            commandArguments: directCommand,
            pidFileURL: artifacts.pidFileURL
        )
        let launch = TerminalLaunch(
            program: "/bin/sh",
            arguments: ["-c", script],
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            workingDirectory: directory,
            environment: Self.surfaceEnvironment(
                pathOverride: environmentPath,
                sessionID: sessionID
            )
        )

        id = sessionID
        self.hostID = hostID
        self.shellPath = shellPath
        self.backend = backend
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent
        agentStatus = nil

        let transport = DaemonTerminalTransport(sessionID: sessionID, identity: daemonIdentity, launch: launch, hostID: hostID, legacyHistory: AppSettings.shared.restoreTerminalHistory ? restoredHistory : nil)
        self.transport = transport
        let surface = backend.makeRemoteSurface(connection: transport)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        transport.onDirectory = { [weak self] path in self?.workingDirectory=path }
        transport.onSession = { [weak self] info, restarted in
            guard let self else { return }
            if hostID == HostGroups.localID { cachedShellPid = pid_t(info.pid) }
            workingDirectory = info.directory
            restoredAsNewShell = restarted
            if restarted { connectionView.markRestart() }
            objectWillChange.send()
        }
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            connectionState = state
            connectionView.update(state)
            if state == .exited {
                hasExited = true
                if !isTerminating { onExited?(self) }
            }
        }
        connectionView.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(connectionView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            connectionView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            connectionView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            connectionView.topAnchor.constraint(equalTo: surface.topAnchor),
            connectionView.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        connectionView.update(connectionState)
        surface.events = self
        imagePasteIndicator.style = .spinning
        imagePasteIndicator.isDisplayedWhenStopped = false
        imagePasteIndicator.toolTip = String(localized: "Uploading image to remote host…")
        imagePasteIndicator.setAccessibilityLabel(String(localized: "Uploading image to remote host…"))
        imagePasteIndicator.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(imagePasteIndicator)
        NSLayoutConstraint.activate([
            imagePasteIndicator.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            imagePasteIndicator.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12)
        ])
        surface.onTakeBackRemoteControl = { [weak self] in
            guard let self else { return }
            RemoteControlService.shared.reclaim(sessionID: self.id)
        }
        installOverlayScrollbar()
        applyTheme()
        applyTheme()
        if hostID == HostGroups.localID { AgentAutomationMonitor.shared.register(self) }
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    /// `makeSurface` returns nil only for a backend this build has no surface
    /// for, and `AppSettings` refuses to store one — so this is belt and
    /// braces, preferring a working terminal over an empty pane.
    private static func makeSurface(
        backend: TerminalBackend, launch: TerminalLaunch
    ) -> any TerminalBackendSurface {
        if let surface = backend.makeSurface(launch: launch) { return surface }
        NSLog("kero: no surface for terminal backend \(backend.rawValue)")
        return KeroTerminalView(launch: launch)
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Reconfigures the surface in place when either appearance or terminal
    /// font settings change.
    func applyTheme() {
        surface.applyAppearance()
        let dark=NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        let settings=AppSettings.shared
        let cursor:UInt8 = [1,3,5][Int(settings.cursorShape.alacrittyValue)] + (settings.cursorBlinking ? 0:1)
        transport.updateColors(Theme.protocolColors(dark:dark),cursorStyle:cursor)
    }

    /// Keep the pane alive until the daemon acknowledges the explicit close.
    func terminate() async -> Bool {
        if hasExited { return true }
        guard !isTerminating else { return false }
        isTerminating = true
        let success = await transport.terminate()
        isTerminating = false
        if success { hasExited = true; removeLaunchArtifacts() }
        else {
            let alert = NSAlert()
            alert.messageText = "Could not confirm that the session ended"
            alert.informativeText = "The operation was not retried. Reconnect to check the session before closing it again."
            alert.runModal()
        }
        return success
    }

    /// Window/group teardown detaches the connection without signalling the
    /// shell or marking it exited. Its identity remains in the saved layout.
    func detach() {
        if isRemotelyControlled { RemoteControlService.shared.reclaim(sessionID:id) }
        transport.close()
        surface.setSurfaceVisible(false)
    }

    func resume() { transport.resume() }

    private func removeLaunchArtifacts() {
        KeroCLIService.shared.revokeTerminal(id: id)
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        guard hostID == HostGroups.localID, let foreground = surface.foregroundProcessID, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        guard !isRemotelyControlled else { return }
        surface.sendText(text)
    }

    func beginRemoteControl(
        resize: RemoteResize,
        output: @escaping (Data) -> Void
    ) {
        guard !isRemotelyControlled else { return }
        isRemotelyControlled = true
        remoteOutputHandler = output
        surface.beginRemoteControl(resize: resize, output: { _ in })
        transport.beginRelay(resize,output:output)
    }

    func endRemoteControl() {
        guard isRemotelyControlled else { return }
        transport.endRelay()
        surface.endRemoteControl()
        remoteOutputHandler = nil
        isRemotelyControlled = false
    }

    func receiveRemoteInput(_ data: Data) {
        guard isRemotelyControlled else { return }
        transport.send(data)
    }

    func applyRemoteResize(_ resize: RemoteResize) {
        guard isRemotelyControlled else { return }
        surface.beginRemoteControl(resize:resize,output:{ _ in })
        transport.resizeRelay(resize)
    }

    func remoteBootstrap() async -> Data? {
        await transport.remoteBootstrap()
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        guard !isRemotelyControlled else { return }
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && surface.foregroundProcessID == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        guard hostID == HostGroups.localID else { return nil }
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    // MARK: - Launch

    private static func surfaceEnvironment(
        pathOverride: String?,
        sessionID: UUID
    ) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            KeroCLIService.shared.terminalEnvironment(for: sessionID),
            uniquingKeysWith: { _, cliValue in cliValue }
        )
        if let pathOverride, !pathOverride.isEmpty {
            environment["PATH"] = pathOverride
        }
        // Locale belongs to the user's shell environment. Kero's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
    }

    private static func makeLaunchArtifacts() -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("kero-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("kero: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil)
        }
    }

    /// The `sh` script every pane starts with: record the process PID and
    /// advertise the emulator, then become either the
    /// requested argv or the user's login shell.
    private static func makeLaunchScript(
        backend: TerminalBackend,
        shellPath: String,
        commandArguments: [String]?,
        pidFileURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        // Legacy history is seeded by the daemon once, never replayed by a shell.
        // KERO_TERM exposes the actual surface. TERM_PROGRAM remains a
        // capability hint so tools select protocols Kero can actually render.
        commands.append("export KERO_TERM=\(shellQuote(backend.environmentName))")
        let termProgram = backend.termProgram
        commands.append("export TERM_PROGRAM=\(shellQuote(termProgram.name))")
        if !termProgram.version.isEmpty {
            commands.append(
                "export TERM_PROGRAM_VERSION=\(shellQuote(termProgram.version))"
            )
        } else {
            commands.append("unset TERM_PROGRAM_VERSION")
        }
        if let commandArguments {
            let argv = commandArguments.map(shellQuote).joined(separator: " ")
            // `env` resolves argv[0] against the caller's PATH. Every argument
            // is quoted independently, so no command text is reparsed or
            // expanded by the launch shim.
            commands.append("exec /usr/bin/env -- \(argv)")
        } else {
            commands.append("exec \(shellQuote(shellPath)) -l")
        }
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
    }

    func terminalDidChangeCellSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0,
              terminalCellSize != size else { return }
        terminalCellSize = size
    }

    func terminalDidRingBell() {
        NSSound.beep()
        guard !surface.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(
            message: String(localized: "Terminal bell"),
            sessionID: id
        )
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        // Renderers own no shell. Only the daemon's exit event can remove a pane.
        detach()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message, sessionID: id)
    }

    func terminalDidRequestOpenURL(_ value: String) {
        guard let target = terminalLinkTarget(for: value) else { return }
        switch target {
        case .file(let fileURL):
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Classifies a detected terminal link only after proving a local path
    /// exists or a non-file URL has a scheme. Context menus and Command-click
    /// use this same answer, so neither offers an action it cannot perform.
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? {
        if hostID != HostGroups.localID {
            // A remote path never becomes a Finder path on the client.
            guard let url=URL(string:value),let scheme=url.scheme,!url.isFileURL,!["vscode","vscode-insiders"].contains(scheme) else{return nil}
            return .url(url)
        }
        if let fileURL = existingFileURL(from: value) {
            return .file(fileURL)
        }
        guard let url = URL(string: value),
              url.scheme != nil,
              !url.isFileURL
        else { return nil }
        return .url(url)
    }

    /// Resolves terminal links the way the shell would: `file:` URLs are
    /// already absolute, `~` belongs to the current user, and other paths are
    /// relative to this pane's live working directory. Diagnostics commonly
    /// append `:line[:column]`, so try the literal path before peeling those
    /// numeric locations off.
    private func existingFileURL(from value: String) -> URL? {
        let candidate: URL
        if let url = URL(string: value), url.scheme != nil {
            guard url.isFileURL else { return nil }
            candidate = url
        } else {
            let decoded = value.removingPercentEncoding ?? value
            let expanded = (decoded as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else {
                let basePath = foregroundDirectoryPath ?? currentDirectoryPath
                candidate = URL(
                    fileURLWithPath: expanded,
                    relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)
                )
            }
        }

        var url = candidate.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let strippedPath = url.path.replacingOccurrences(
                of: #":\d+$"#,
                with: "",
                options: .regularExpression
            )
            guard strippedPath != url.path else { return nil }
            url = URL(fileURLWithPath: strippedPath).standardizedFileURL
        }
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        terminalIsAtLiveBottom = position.position >= 0.999
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste")
            : String(localized: "Allow"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel")
                : String(localized: "Deny")
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    func terminalHandleImagePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard hostID != HostGroups.localID, let source = RemoteImagePaste.capture(pasteboard) else { return false }
        guard imagePasteTask == nil else { NSSound.beep(); return true }
        guard isConnected, !isRemotelyControlled, let key = daemonIdentity else {
            imagePasteError("Expand and connect the host before pasting an image.")
            return true
        }
        guard RemoteImagePaste.begin() else { NSSound.beep(); return true }
        let service = HostGroups.shared.service(hostID)
        imagePasteIndicator.startAnimation(nil)
        imagePasteTask = Task { [weak self] in
            defer { RemoteImagePaste.finish() }
            do {
                let path = try await Task.detached {
                    try service.uploadImage(RemoteImagePaste.png(source), key: key)
                }.value
                guard let self else { return }
                defer { imagePasteTask = nil; imagePasteIndicator.stopAnimation(nil) }
                // A collapse/reconnect, cold restart or control handoff must
                // never insert a late attachment into a different prompt.
                guard !Task.isCancelled, isConnected, !isRemotelyControlled,
                      daemonIdentity == key, surface.window != nil,
                      HostGroups.shared.isExpanded(hostID), HostGroups.shared.service(hostID) === service else { return }
                transport.pasteImagePath(path)
            } catch {
                guard let self else { return }
                imagePasteTask = nil
                imagePasteIndicator.stopAnimation(nil)
                if surface.window != nil { imagePasteError(error.localizedDescription + "\nThe image was not pasted or retried.") }
            }
        }
        return true
    }

    private func imagePasteError(_ message: String) {
        guard let window = surface.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not paste image")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    /// Bounded, read-only preview of the text under decision, mirroring
    /// the preview area in Ghostty's own confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}
