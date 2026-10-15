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
    /// What a click does; the menu then opens on a long press instead.
    var primaryAction: (() -> Void)?
    let content: Content
    @State private var hover = false

    public init(systemName: String = "ellipsis", large: Bool = false, primaryAction: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.systemName = systemName
        self.large = large
        self.primaryAction = primaryAction
        self.content = content()
    }

    public var body: some View {
        // The button menu style keeps the label's frame and background; the
        // borderless one draws only the glyph.
        Group {
            if let primaryAction {
                Menu {
                    content
                } label: {
                    IconFace(systemName: systemName, large: large, hover: hover)
                } primaryAction: {
                    primaryAction()
                }
            } else {
                Menu {
                    content
                } label: {
                    IconFace(systemName: systemName, large: large, hover: hover)
                }
            }
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
            .font(.ui(large ? 14 : 12.5, weight: .medium))
            .frame(width: Touch.row(large ? 32 : 24), height: Touch.row(large ? 30 : 22))
            .background(RoundedRectangle(cornerRadius: large ? 8 : 6).fill(Color.white.opacity(hover ? 0.10 : 0)))
            .contentShape(Rectangle())
    }
}

public enum RelativeTime {
    public static func short(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        switch s {
        case ..<60: return String(localized: "now", bundle: .vhosttyUIResources)
        case ..<3600: return String(localized: "\(Int(s / 60))m", bundle: .vhosttyUIResources)
        case ..<86400: return String(localized: "\(Int(s / 3600))h", bundle: .vhosttyUIResources)
        case ..<(86400 * 30): return String(localized: "\(Int(s / 86400))d", bundle: .vhosttyUIResources)
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

/// Sizes for the input in use: the desktop's own for a pointer, larger on
/// iPhone and iPad for fingers. The views are the same; only these differ.
public enum Touch {
    #if os(iOS)
    /// Text and the space around it: 13.5pt (a project's name) becomes 17pt.
    public static let scale: CGFloat = 1.27
    /// The shortest a tappable row gets (Apple's minimum tap target).
    public static let minRow: CGFloat = 44
    #else
    public static let scale: CGFloat = 1
    public static let minRow: CGFloat = 0
    #endif

    public static func size(_ points: CGFloat) -> CGFloat { points * scale }
    /// A row's height: scaled, and tall enough to tap.
    public static func row(_ points: CGFloat) -> CGFloat { max(points * scale, minRow) }
}

extension Font {
    /// The system font at a desktop size, scaled for touch.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: Touch.size(size), weight: weight, design: design)
    }
}

extension View {
    /// Tall enough to tap (touch only).
    func tapHeight() -> some View {
        #if os(iOS)
        frame(minHeight: Touch.minRow)
        #else
        self
        #endif
    }
}
