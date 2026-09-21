//
//  SidebarView.swift
//  kero
//

import AppKit
import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    let manager: TerminalManager
    let bottomBarHeight: CGFloat
    @Environment(\.openSettings) private var openSettings
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    var body: some View {
        HostSidebarRepresentable(manager: manager, bottomBarHeight: bottomBarHeight, openSettings: { openSettings() })
            .frame(width: width)
    }
}

struct ChromeIconButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    var font: Font = .system(size: 12, weight: .medium)
    var iconSize: CGFloat = 16
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}

/// Live frames-per-second readout in the header strip, fed by `FPSCounter`.
/// It exists only while the manager's toggle is on, so the counter starts
/// when the badge appears and stops when it leaves the hierarchy.
private struct FPSBadge: View {
    @StateObject private var counter = FPSCounter()

    var body: some View {
        Text("\(counter.fps) fps")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
            )
            .onAppear { counter.start() }
            .onDisappear { counter.stop() }
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: View {
    @ObservedObject var project: Project
    @ObservedObject private var themeChanges = Theme.changes
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                rowContent
            } else {
                Button(action: select) {
                    rowContent
                }
                .buttonStyle(.plain)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.location) }
                        .onEnded { _ in onDragEnded() }
                )
            }
        }
        .opacity(isDragging ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…") {
                beginRename()
            }
            if project.customName != nil {
                Button("Use Automatic Title") {
                    project.customName = nil
                }
            }
            Divider()
            Button("Set Project Directory…") {
                pickProjectDirectory()
            }
            if project.customDirectory != nil {
                Button("Use Automatic Directory") {
                    project.customDirectory = nil
                }
            }
            Divider()
            Button("Close Project") {
                close()
            }
        }
    }

    /// Lets the user pin the project's directory — the root the file tree
    /// and git panels anchor to instead of the automatic closest-git-repo.
    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button in the project directory picker.")
        panel.message = String(
            localized: "Choose the directory for “\(project.name)”.",
            comment: "Message in the project directory picker. The placeholder is a project name."
        )
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.accent) : .secondary)
                .frame(width: max(14, fontSize), alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: projectTitleFontSize, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) {
                            if !renameFocused, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: projectTitleFontSize))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                subtitle
            }

            Spacer(minLength: 0)

            if let rollup = project.agentRollup, !isRenaming {
                AgentStatusBadgeRepresentable(rollup: rollup)
                    .fixedSize()
            }

            // Fixed trailing slot: close and the ⌘N hint share the same
            // width so hover does not reflow the row. Continuous title
            // updates from the terminal re-render the strip; without a
            // stable slot that reflow reads as jitter under the pointer.
            ZStack(alignment: .trailing) {
                if isHovering, !isRenaming {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if index < 9, !isRenaming {
                    Text(verbatim: "⌘\(index + 1)")
                        .font(.system(size: supportingFontSize))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 16, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func beginRename() {
        renameDraft = project.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        project.customName = Project.normalizedCustomName(renameDraft)
        isRenaming = false
    }

    @ViewBuilder
    private var subtitle: some View {
        if project.sessions.count > 1 {
            Text("\(project.sessions.count) sessions")
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session, fontSize: supportingFontSize)
        }
    }

    private var supportingFontSize: Double {
        10 * sidebarFontScale
    }

    /// Match the file-tree label's designed 11.5 pt size while following the
    /// shared sidebar font-size setting.
    private var projectTitleFontSize: Double {
        11.5 * sidebarFontScale
    }

    private var sidebarFontScale: Double {
        fontSize / AppSettings.defaultSidebarFontSize
    }
}

/// Small subtitle showing a session's current directory; separate view so
/// it observes the session's own published working directory.
private struct SessionDirectoryLabel: View {
    @ObservedObject var session: TerminalSession
    let fontSize: Double

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
