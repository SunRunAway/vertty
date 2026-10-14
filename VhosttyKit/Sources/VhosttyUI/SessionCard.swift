import SwiftUI

/// A session in the sidebar: a four-line card showing
/// title / branch / worktree / PR.
struct SessionCard<Store: SidebarStore>: View {
    @ObservedObject var card: Store.Card
    @ObservedObject var store: Store
    @Binding var draggingID: UUID?
    @State private var hover = false
    @Environment(\.openURL) private var openURL

    private var selected: Bool { store.selectedCardID == card.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Touch.size(3)) {
            HStack(spacing: Touch.size(7)) {
                StatusIndicator(status: card.status, attention: card.attention, kind: card.kind)
                AgentIcon(kind: card.kind, size: Touch.size(11))
                if let task = store.scheduleName(for: card) {
                    Image(systemName: "clock")
                        .font(.ui(9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(Text("Scheduled task: \(task)", bundle: .module))
                }
                Text(card.title)
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                #if os(macOS)
                // Touch screens close from the card's menu (long press).
                closeButton
                #endif
            }
            .frame(height: Touch.size(18))

            infoLine("arrow.triangle.branch", card.branch, placeholder: String(localized: "No branch info", bundle: .module))
            infoLine("square.stack.3d.up", card.worktree,
                     placeholder: card.branch == nil ? "—" : String(localized: "Main worktree", bundle: .module),
                     tint: card.worktree == nil ? .secondary : Color(red: 0.72, green: 0.55, blue: 1.0))
            prLine
        }
        .padding(.leading, Touch.size(9))
        .padding(.trailing, Touch.size(7))
        .padding(.vertical, Touch.size(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.white.opacity(0.11) : Color.white.opacity(hover ? 0.06 : 0.025)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.white.opacity(selected ? 0.16 : 0.05), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .opacity(draggingID == card.id ? 0.45 : 1)
        .onHover { hover = $0 }
        .onTapGesture { store.select(card) }
        .reorderable(store.features.contains(.reorder), id: card.id, dragging: $draggingID) { id in
            store.moveCard(id, before: card.id)
        }
        .help(card.title)
        .contextMenu { contextMenu }
    }

    private var closeButton: some View {
        Button { store.requestClose(card) } label: {
            Image(systemName: "xmark")
                .font(.ui(8.5, weight: .bold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hover ? 1 : 0)
        .help(Text("Close (⌘W)", bundle: .module))
    }

    private func infoLine(_ icon: String, _ text: String?, placeholder: String, tint: Color = .secondary) -> some View {
        HStack(spacing: Touch.size(6)) {
            Image(systemName: icon)
                .font(.ui(10, weight: .medium))
                .foregroundStyle(text == nil ? Color.secondary.opacity(0.5) : tint)
                .frame(width: Touch.size(13))
            Text(text ?? placeholder)
                .font(.ui(11.5, design: text == nil ? .default : .monospaced))
                .foregroundStyle(text == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: Touch.size(15))
    }

    private var prLine: some View {
        HStack(spacing: Touch.size(6)) {
            Image(systemName: "arrow.triangle.pull")
                .font(.ui(10, weight: .medium))
                .foregroundStyle(card.prNumber == nil ? Color.secondary.opacity(0.5) : prColor)
                .frame(width: Touch.size(13))
            if let n = card.prNumber {
                Text(verbatim: "#\(n)")
                    .font(.ui(11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(prColor)
                if let state = card.prState, state != "OPEN" {
                    Text(state == "MERGED" ? String(localized: "Merged", bundle: .module) : String(localized: "Closed", bundle: .module))
                        .font(.ui(10.5))
                        .foregroundStyle(.tertiary)
                }
                if card.prURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.ui(8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No PR", bundle: .module)
                    .font(.ui(11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: Touch.size(15))
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = card.prURL, let url = URL(string: s) { openURL(url) } else { store.select(card) }
        }
        .help(card.prURL.map { Text("Open \($0) in Browser", bundle: .module) } ?? Text(verbatim: ""))
    }

    private var prColor: Color {
        switch card.prState {
        case "MERGED": return Color(red: 0.70, green: 0.52, blue: 1.0)
        case "CLOSED": return Color(red: 0.95, green: 0.42, blue: 0.42)
        default: return Color(red: 0.38, green: 0.82, blue: 0.48)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button { store.requestClose(card) } label: { Text("Close", bundle: .module) }
        if store.features.contains(.closeOthers) {
            Button { store.closeOthers(card) } label: { Text("Close Other Sessions", bundle: .module) }
        }
        Divider()
        if let s = card.prURL, let url = URL(string: s) {
            Button { openURL(url) } label: { Text("Open PR #\(card.prNumber ?? 0) in Browser", bundle: .module) }
        }
        if store.features.contains(.localFiles), let dir = store.directory(of: card) {
            Button { Platform.reveal(dir) } label: { Text("Show Directory in Finder", bundle: .module) }
        }
        if !card.sessionID.isEmpty {
            Button { Platform.copy(card.sessionID) } label: { Text("Copy Session ID", bundle: .module) }
            Button {
                Platform.copy(card.kind == .claude ? "claude --resume \(card.sessionID)" : "codex resume \(card.sessionID)")
            } label: { Text("Copy Resume Command", bundle: .module) }
        }
    }
}

public struct StatusIndicator: View {
    let status: SessionStatus
    let attention: Bool
    var kind: AgentKind = .claude

    public init(status: SessionStatus, attention: Bool, kind: AgentKind = .claude) {
        self.status = status
        self.attention = attention
        self.kind = kind
    }

    public var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView().controlSize(.mini).scaleEffect(0.75)
            case .needsInput:
                Image(systemName: "hand.raised.fill")
                    .font(.ui(9.5))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
            case .idle:
                Circle()
                    .fill(attention ? Color(red: 0.35, green: 0.62, blue: 1.0) : Color.clear)
                    .frame(width: Touch.size(7), height: Touch.size(7))
            case .starting:
                Circle().fill(Color.gray.opacity(0.7)).frame(width: Touch.size(7), height: Touch.size(7))
            case .dormant, .exited:
                Circle().strokeBorder(Color.gray.opacity(0.8), lineWidth: 1.2).frame(width: Touch.size(7), height: Touch.size(7))
            }
        }
        .frame(width: Touch.size(12), height: Touch.size(12))
        .help(statusHelp)
    }

    private var statusHelp: String {
        switch status {
        case .working: return String(localized: "\(kind.name) is working", bundle: .module)
        case .needsInput: return String(localized: "\(kind.name) needs your input", bundle: .module)
        case .idle: return attention ? String(localized: "\(kind.name) is done (unread)", bundle: .module) : String(localized: "Waiting for input", bundle: .module)
        case .starting: return String(localized: "Starting", bundle: .module)
        case .dormant: return String(localized: "Not started (click to resume)", bundle: .module)
        case .exited: return String(localized: "\(kind.name) exited", bundle: .module)
        }
    }
}
