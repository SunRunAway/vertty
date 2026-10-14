import SwiftUI

/// The mark of the agent a session runs: Claude's spark or Codex's ">_".
public struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 12

    public init(kind: AgentKind, size: CGFloat = 12) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        Group {
            switch kind {
            case .claude:
                ClaudeSpark()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            case .codex:
                RoundedRectangle(cornerRadius: size * 0.26)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.36, blue: 0.96)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(CodexPrompt().stroke(.white, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round)))
            }
        }
        .frame(width: size, height: size)
        .help(kind.name)
    }
}

/// Rays of slightly varying length around a center, like Claude's logo.
private struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let rays = 12
        let width = r * 0.24
        var path = Path()
        for i in 0..<rays {
            let length = r * (i.isMultiple(of: 2) ? 1.0 : 0.82)
            let ray = Path(roundedRect: CGRect(x: -width / 2, y: -width / 2, width: width, height: length + width / 2),
                           cornerRadius: width / 2)
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi
            path.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
        }
        return path
    }
}

/// ">_", the prompt Codex shows in its banner.
private struct CodexPrompt: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.30))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.44, y: rect.minY + h * 0.50))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.70))
        path.move(to: CGPoint(x: rect.minX + w * 0.54, y: rect.minY + h * 0.70))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.70))
        return path
    }
}
