import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct IconButton: View {
    let systemName: String
    let help: Text
    /// Drawn brighter while what it toggles is on.
    var active = false
    var large = false
    let action: () -> Void
    @State private var hover = false

    public init(systemName: String, help: Text, active: Bool = false, large: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.active = active
        self.large = large
        self.action = action
    }

    /// `help` from the app's own strings.
    public init(systemName: String, help: LocalizedStringKey, active: Bool = false, large: Bool = false, action: @escaping () -> Void) {
        self.init(systemName: systemName, help: Text(help), active: active, large: large, action: action)
    }

    public var body: some View {
        Button(action: action) {
            IconFace(systemName: systemName, large: large, hover: hover)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// An icon that opens a menu, looking and hovering like an IconButton.
public struct IconMenu<Content: View>: View {
    var systemName = "ellipsis"
    var large = false
    let content: Content
    @State private var hover = false

    public init(systemName: String = "ellipsis", large: Bool = false, @ViewBuilder content: () -> Content) {
        self.systemName = systemName
        self.large = large
        self.content = content()
    }

    public var body: some View {
        // The button menu style keeps the label's frame and background; the
        // borderless one draws only the glyph.
        Menu {
            content
        } label: {
            IconFace(systemName: systemName, large: large, hover: hover)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
    }
}

/// The glyph and hover square of an IconButton or IconMenu; the square is
/// what takes the click.
private struct IconFace: View {
    let systemName: String
    let large: Bool
    let hover: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: large ? 14 : 12.5, weight: .medium))
            .frame(width: large ? 32 : 24, height: large ? 30 : 22)
            .background(RoundedRectangle(cornerRadius: large ? 8 : 6).fill(Color.white.opacity(hover ? 0.10 : 0)))
            .contentShape(Rectangle())
    }
}

public enum RelativeTime {
    public static func short(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        switch s {
        case ..<60: return String(localized: "now", bundle: .module)
        case ..<3600: return String(localized: "\(Int(s / 60))m", bundle: .module)
        case ..<86400: return String(localized: "\(Int(s / 3600))h", bundle: .module)
        case ..<(86400 * 30): return String(localized: "\(Int(s / 86400))d", bundle: .module)
        default:
            let f = DateFormatter()
            f.dateFormat = "M/d"
            return f.string(from: date)
        }
    }
}

/// What differs per platform in the shared views.
enum Platform {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Shows a directory on this Mac in Finder.
    static func reveal(_ path: String) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #endif
    }
}
