import SwiftUI
import UniformTypeIdentifiers

/// A session in the sidebar: a four-line card showing
/// title / branch / worktree / PR.
struct SessionCard: View {
    @ObservedObject var tab: TabSession
    @ObservedObject var store: AppStore
    @Binding var draggingID: UUID?
    @State private var hover = false

    private var selected: Bool { store.selectedTabID == tab.id }

    /// The scheduled task this card's session belongs to (or that started it).
    private var scheduleTask: ScheduleTask? {
        store.schedules.task(forSession: tab.sessionID) ?? tab.scheduleTaskID.flatMap(store.schedules.task)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                StatusIndicator(status: tab.status, attention: tab.attention, kind: tab.kind)
                AgentIcon(kind: tab.kind, size: 11)
                if let task = scheduleTask {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(String(localized: "Scheduled task: \(task.name)"))
                }
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                closeButton
            }
            .frame(height: 18)

            infoLine("arrow.triangle.branch", tab.branch, placeholder: String(localized: "No branch info"))
            infoLine("square.stack.3d.up", tab.worktree, placeholder: tab.branch == nil ? "—" : String(localized: "Main worktree"),
                     tint: tab.worktree == nil ? .secondary : Color(red: 0.72, green: 0.55, blue: 1.0))
            prLine
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.white.opacity(0.11) : Color.white.opacity(hover ? 0.06 : 0.025)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(selected ? 0.16 : 0.05), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .opacity(draggingID == tab.id ? 0.45 : 1)
        .onHover { hover = $0 }
        .onTapGesture { store.select(tab) }
        .onDrag {
            draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: CardDropDelegate(target: tab.id, store: store, draggingID: $draggingID))
        .help(tab.title)
        .contextMenu { contextMenu }
    }

    private var closeButton: some View {
        Button { store.requestClose(tab) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hover ? 1 : 0)
        .help("Close (⌘W)")
    }

    private func infoLine(_ icon: String, _ text: String?, placeholder: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(text == nil ? Color.secondary.opacity(0.5) : tint)
                .frame(width: 13)
            Text(text ?? placeholder)
                .font(.system(size: 11.5, design: text == nil ? .default : .monospaced))
                .foregroundStyle(text == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 15)
    }

    private var prLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tab.prNumber == nil ? Color.secondary.opacity(0.5) : prColor)
                .frame(width: 13)
            if let n = tab.prNumber {
                Text("#\(n)")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(prColor)
                if let state = tab.prState, state != "OPEN" {
                    Text(state == "MERGED" ? String(localized: "Merged") : String(localized: "Closed"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                if tab.prURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No PR")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 15)
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = tab.prURL, let url = URL(string: s) { NSWorkspace.shared.open(url) } else { store.select(tab) }
        }
        .help(tab.prURL.map { String(localized: "Open \($0) in Browser") } ?? "")
    }

    private var prColor: Color {
        switch tab.prState {
        case "MERGED": return Color(red: 0.70, green: 0.52, blue: 1.0)
        case "CLOSED": return Color(red: 0.95, green: 0.42, blue: 0.42)
        default: return Color(red: 0.38, green: 0.82, blue: 0.48)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Close") { store.requestClose(tab) }
        Button("Close Other Sessions") { store.closeOtherTabs(tab) }
        Divider()
        if let s = tab.prURL, let url = URL(string: s) {
            Button("Open PR #\(tab.prNumber ?? 0) in Browser") { NSWorkspace.shared.open(url) }
        }
        Button("Show Directory in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.cwd)])
        }
        if !tab.sessionID.isEmpty {
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.sessionID, forType: .string)
            }
            Button("Copy Resume Command") {
                NSPasteboard.general.clearContents()
                let command = tab.kind == .claude ? "claude --resume \(tab.sessionID)" : "codex resume \(tab.sessionID)"
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}

struct StatusIndicator: View {
    let status: SessionStatus
    let attention: Bool
    var kind: AgentKind = .claude

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            case .needsInput:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
            case .idle:
                Circle()
                    .fill(attention ? Color(red: 0.35, green: 0.62, blue: 1.0) : Color.clear)
                    .frame(width: 7, height: 7)
            case .starting:
                Circle().fill(Color.gray.opacity(0.7)).frame(width: 7, height: 7)
            case .dormant, .exited:
                Circle().strokeBorder(Color.gray.opacity(0.8), lineWidth: 1.2).frame(width: 7, height: 7)
            }
        }
        .frame(width: 12, height: 12)
        .help(statusHelp)
    }

    private var statusHelp: String {
        switch status {
        case .working: return String(localized: "\(kind.name) is working")
        case .needsInput: return String(localized: "\(kind.name) needs your input")
        case .idle: return attention ? String(localized: "\(kind.name) is done (unread)") : String(localized: "Waiting for input")
        case .starting: return String(localized: "Starting")
        case .dormant: return String(localized: "Not started (click to resume)")
        case .exited: return String(localized: "\(kind.name) exited")
        }
    }
}

private struct CardDropDelegate: DropDelegate {
    let target: UUID
    let store: AppStore
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let id = draggingID, id != target else { return }
        withAnimation(.easeOut(duration: 0.12)) { store.moveTab(id, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
