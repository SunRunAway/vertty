import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The sidebar's place in the window: shown or hidden, and its width.
public protocol SidebarLayoutModel: ObservableObject {
    var sidebarVisible: Bool { get }
    var sidebarWidth: CGFloat { get set }
    func toggleSidebar()
    /// The user finished dragging the sidebar's edge.
    func sidebarResized()
}

/// The window (Mac, iPad): the sidebar on the left with a draggable edge,
/// and the title strip above the content on the right.
public struct Workspace<Layout: SidebarLayoutModel, Sidebar: View, Strip: View, Detail: View>: View {
    @ObservedObject var layout: Layout
    let sidebar: Sidebar
    let strip: Strip
    let detail: Detail
    @State private var dragStartWidth: CGFloat?

    public init(layout: Layout, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder strip: () -> Strip,
                @ViewBuilder detail: () -> Detail) {
        self.layout = layout
        self.sidebar = sidebar()
        self.strip = strip()
        self.detail = detail()
    }

    public var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarVisible {
                sidebar
                    .frame(width: layout.sidebarWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            }
            VStack(spacing: 0) {
                strip
                detail
            }
        }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .resizeCursor()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? layout.sidebarWidth
                        dragStartWidth = start
                        layout.sidebarWidth = min(max(start + value.translation.width, 230), 520)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        layout.sidebarResized()
                    })
    }
}

/// The top of the sidebar: room for the window controls, and the button that
/// hides the sidebar.
public struct SidebarTopBar<Layout: SidebarLayoutModel>: View {
    @ObservedObject var layout: Layout

    public init(layout: Layout) { self.layout = layout }

    public var body: some View {
        Color.clear.frame(height: Self.height) // traffic lights
            .background(WindowDragArea())
            .overlay(alignment: .trailing) {
                SidebarToggleButton(layout: layout)
                    .padding(.trailing, 10)
            }
    }

    static var height: CGFloat {
        #if os(macOS)
        40
        #else
        Touch.minRow
        #endif
    }
}

public struct SidebarToggleButton<Layout: SidebarLayoutModel>: View {
    @ObservedObject var layout: Layout

    public init(layout: Layout) { self.layout = layout }

    public var body: some View {
        IconButton(systemName: "sidebar.left",
                   help: layout.sidebarVisible ? Text("Hide Sidebar (⌃⌘S)", bundle: .module) : Text("Show Sidebar (⌃⌘S)", bundle: .module)) {
            layout.toggleSidebar()
        }
    }
}

/// Slim draggable strip above the terminal showing what's selected.
public struct TitleStrip<Layout: SidebarLayoutModel, Label: View, Trailing: View>: View {
    @ObservedObject var layout: Layout
    let background: Color
    let label: Label
    let trailing: Trailing

    public init(layout: Layout, background: Color, @ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing) {
        self.layout = layout
        self.background = background
        self.label = label()
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            WindowDragArea()
            label
                .allowsHitTesting(false)
            HStack(spacing: 6) {
                Spacer()
                trailing
            }
            .padding(.trailing, 10)
        }
        // Room for the window controls and the sidebar button while the
        // sidebar is hidden.
        .padding(.leading, layout.sidebarVisible ? 0 : Self.hiddenSidebarInset)
        .overlay(alignment: .leading) {
            if !layout.sidebarVisible {
                SidebarToggleButton(layout: layout)
                    .padding(.leading, Self.hiddenSidebarInset - Touch.row(24) - 8)
            }
        }
        .frame(height: Chrome.titleStripHeight)
        .background(background)
    }

    private static var hiddenSidebarInset: CGFloat {
        #if os(macOS)
        112
        #else
        60
        #endif
    }
}

public enum Chrome {
    public static let titleStripHeight: CGFloat = Touch.row(34)
}

/// "Project / session title" in the title strip.
public struct TitleStripLabel<Card: SessionCardModel>: View {
    @ObservedObject var card: Card
    let project: Project?

    public init(card: Card, project: Project?) {
        self.card = card
        self.project = project
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let project {
                Text(project.name).foregroundStyle(.tertiary)
                Text(verbatim: "/").foregroundStyle(.quaternary)
            }
            Text(card.title).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.ui(12, weight: .medium))
        .padding(.horizontal, 16)
    }
}

/// Empty bar space that drags the window (and zooms on double-click). Just
/// space where windows don't move.
public struct WindowDragArea: View {
    public init() {}

    public var body: some View {
        #if os(macOS)
        DragArea()
        #else
        Color.clear
        #endif
    }
}

#if os(macOS)
private struct DragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

extension View {
    /// The left-right resize cursor over a draggable edge (Mac).
    func resizeCursor() -> some View {
        #if os(macOS)
        onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        #else
        self
        #endif
    }
}
