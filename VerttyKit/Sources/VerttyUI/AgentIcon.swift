import SwiftUI

/// The mark of the agent a session runs: Claude's spark, Codex's ">_", or
/// DeepSeek's whale.
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
            case .deepseekClaude:
                DeepSeekWhale()
                    .fill(Color(red: 0.30, green: 0.42, blue: 1.0))
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

/// DeepSeek's whale, traced from its logo.
private struct DeepSeekWhale: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 440.9, y: 139.2))
        p.addCurve(to: CGPoint(x: 432.8, y: 142.8), control1: CGPoint(x: 436.9, y: 137.2), control2: CGPoint(x: 435.2, y: 140.9))
        p.addCurve(to: CGPoint(x: 430.7, y: 145.0), control1: CGPoint(x: 432.0, y: 143.5), control2: CGPoint(x: 431.4, y: 144.2))
        p.addCurve(to: CGPoint(x: 409.1, y: 154.8), control1: CGPoint(x: 424.8, y: 151.2), control2: CGPoint(x: 418.0, y: 155.3))
        p.addCurve(to: CGPoint(x: 375.0, y: 168.2), control1: CGPoint(x: 396.0, y: 154.1), control2: CGPoint(x: 384.9, y: 158.2))
        p.addCurve(to: CGPoint(x: 355.4, y: 143.8), control1: CGPoint(x: 372.9, y: 155.9), control2: CGPoint(x: 366.0, y: 148.5))
        p.addCurve(to: CGPoint(x: 340.4, y: 133.6), control1: CGPoint(x: 349.9, y: 141.4), control2: CGPoint(x: 344.3, y: 138.9))
        p.addCurve(to: CGPoint(x: 335.6, y: 121.4), control1: CGPoint(x: 337.7, y: 129.8), control2: CGPoint(x: 336.9, y: 125.6))
        p.addCurve(to: CGPoint(x: 331.0, y: 115.9), control1: CGPoint(x: 334.7, y: 118.9), control2: CGPoint(x: 333.9, y: 116.3))
        p.addCurve(to: CGPoint(x: 325.4, y: 120.2), control1: CGPoint(x: 327.8, y: 115.4), control2: CGPoint(x: 326.6, y: 118.0))
        p.addCurve(to: CGPoint(x: 318.7, y: 149.2), control1: CGPoint(x: 320.4, y: 129.2), control2: CGPoint(x: 318.5, y: 139.2))
        p.addCurve(to: CGPoint(x: 347.6, y: 202.6), control1: CGPoint(x: 319.1, y: 171.8), control2: CGPoint(x: 328.7, y: 189.8))
        p.addCurve(to: CGPoint(x: 349.7, y: 207.7), control1: CGPoint(x: 349.8, y: 204.1), control2: CGPoint(x: 350.4, y: 205.5))
        p.addCurve(to: CGPoint(x: 345.5, y: 220.8), control1: CGPoint(x: 348.4, y: 212.1), control2: CGPoint(x: 346.8, y: 216.4))
        p.addCurve(to: CGPoint(x: 340.3, y: 223.0), control1: CGPoint(x: 344.6, y: 223.6), control2: CGPoint(x: 343.3, y: 224.2))
        p.addCurve(to: CGPoint(x: 313.0, y: 204.4), control1: CGPoint(x: 329.9, y: 218.6), control2: CGPoint(x: 320.9, y: 212.2))
        p.addCurve(to: CGPoint(x: 272.1, y: 165.7), control1: CGPoint(x: 299.5, y: 191.4), control2: CGPoint(x: 287.3, y: 177.0))
        p.addCurve(to: CGPoint(x: 261.3, y: 158.3), control1: CGPoint(x: 268.6, y: 163.1), control2: CGPoint(x: 265.0, y: 160.7))
        p.addCurve(to: CGPoint(x: 267.4, y: 129.4), control1: CGPoint(x: 245.8, y: 143.3), control2: CGPoint(x: 263.3, y: 130.9))
        p.addCurve(to: CGPoint(x: 255.1, y: 122.7), control1: CGPoint(x: 271.6, y: 127.9), control2: CGPoint(x: 268.9, y: 122.6))
        p.addCurve(to: CGPoint(x: 212.8, y: 133.5), control1: CGPoint(x: 241.4, y: 122.8), control2: CGPoint(x: 228.8, y: 127.3))
        p.addCurve(to: CGPoint(x: 205.5, y: 135.6), control1: CGPoint(x: 210.5, y: 134.4), control2: CGPoint(x: 208.0, y: 135.1))
        p.addCurve(to: CGPoint(x: 160.1, y: 134.0), control1: CGPoint(x: 191.0, y: 132.9), control2: CGPoint(x: 175.9, y: 132.2))
        p.addCurve(to: CGPoint(x: 89.4, y: 175.3), control1: CGPoint(x: 130.5, y: 137.3), control2: CGPoint(x: 106.8, y: 151.3))
        p.addCurve(to: CGPoint(x: 69.5, y: 270.9), control1: CGPoint(x: 68.4, y: 204.1), control2: CGPoint(x: 63.5, y: 236.8))
        p.addCurve(to: CGPoint(x: 122.4, y: 359.9), control1: CGPoint(x: 75.9, y: 306.8), control2: CGPoint(x: 94.2, y: 336.6))
        p.addCurve(to: CGPoint(x: 223.7, y: 393.5), control1: CGPoint(x: 151.6, y: 384.0), control2: CGPoint(x: 185.3, y: 395.8))
        p.addCurve(to: CGPoint(x: 302.3, y: 364.3), control1: CGPoint(x: 247.1, y: 392.2), control2: CGPoint(x: 273.0, y: 389.1))
        p.addCurve(to: CGPoint(x: 330.3, y: 370.5), control1: CGPoint(x: 309.7, y: 367.9), control2: CGPoint(x: 317.5, y: 369.4))
        p.addCurve(to: CGPoint(x: 357.2, y: 368.5), control1: CGPoint(x: 340.3, y: 371.4), control2: CGPoint(x: 349.8, y: 370.0))
        p.addCurve(to: CGPoint(x: 363.8, y: 353.4), control1: CGPoint(x: 368.8, y: 366.0), control2: CGPoint(x: 368.0, y: 355.3))
        p.addCurve(to: CGPoint(x: 330.5, y: 338.8), control1: CGPoint(x: 329.9, y: 337.6), control2: CGPoint(x: 337.3, y: 344.0))
        p.addCurve(to: CGPoint(x: 383.9, y: 228.6), control1: CGPoint(x: 347.8, y: 318.4), control2: CGPoint(x: 373.7, y: 297.2))
        p.addCurve(to: CGPoint(x: 383.9, y: 215.3), control1: CGPoint(x: 384.7, y: 223.1), control2: CGPoint(x: 384.0, y: 219.7))
        p.addCurve(to: CGPoint(x: 387.5, y: 211.2), control1: CGPoint(x: 383.8, y: 212.6), control2: CGPoint(x: 384.5, y: 211.5))
        p.addCurve(to: CGPoint(x: 411.8, y: 203.8), control1: CGPoint(x: 396.0, y: 210.3), control2: CGPoint(x: 404.3, y: 207.9))
        p.addCurve(to: CGPoint(x: 444.8, y: 148.4), control1: CGPoint(x: 433.8, y: 191.8), control2: CGPoint(x: 442.7, y: 172.1))
        p.addCurve(to: CGPoint(x: 440.9, y: 139.2), control1: CGPoint(x: 445.1, y: 144.8), control2: CGPoint(x: 444.7, y: 141.1))
        p.closeSubpath()
        p.move(to: CGPoint(x: 249.4, y: 351.9))
        p.addCurve(to: CGPoint(x: 194.0, y: 317.9), control1: CGPoint(x: 216.5, y: 326.1), control2: CGPoint(x: 200.6, y: 317.5))
        p.addCurve(to: CGPoint(x: 190.3, y: 329.9), control1: CGPoint(x: 187.8, y: 318.3), control2: CGPoint(x: 189.0, y: 325.3))
        p.addCurve(to: CGPoint(x: 196.2, y: 341.5), control1: CGPoint(x: 191.7, y: 334.4), control2: CGPoint(x: 193.6, y: 337.6))
        p.addCurve(to: CGPoint(x: 194.4, y: 351.0), control1: CGPoint(x: 197.9, y: 344.2), control2: CGPoint(x: 199.2, y: 348.1))
        p.addCurve(to: CGPoint(x: 164.5, y: 348.4), control1: CGPoint(x: 183.8, y: 357.6), control2: CGPoint(x: 165.4, y: 348.8))
        p.addCurve(to: CGPoint(x: 112.6, y: 296.4), control1: CGPoint(x: 143.1, y: 335.8), control2: CGPoint(x: 125.2, y: 319.1))
        p.addCurve(to: CGPoint(x: 92.1, y: 225.8), control1: CGPoint(x: 100.4, y: 274.4), control2: CGPoint(x: 93.3, y: 250.9))
        p.addCurve(to: CGPoint(x: 99.6, y: 216.5), control1: CGPoint(x: 91.8, y: 219.8), control2: CGPoint(x: 93.6, y: 217.6))
        p.addCurve(to: CGPoint(x: 123.7, y: 215.9), control1: CGPoint(x: 107.6, y: 215.0), control2: CGPoint(x: 115.8, y: 214.7))
        p.addCurve(to: CGPoint(x: 209.8, y: 259.5), control1: CGPoint(x: 157.2, y: 220.8), control2: CGPoint(x: 185.8, y: 235.8))
        p.addCurve(to: CGPoint(x: 244.4, y: 305.0), control1: CGPoint(x: 223.4, y: 273.1), control2: CGPoint(x: 233.8, y: 289.2))
        p.addCurve(to: CGPoint(x: 283.4, y: 350.9), control1: CGPoint(x: 255.7, y: 321.8), control2: CGPoint(x: 267.9, y: 337.8))
        p.addCurve(to: CGPoint(x: 297.5, y: 361.6), control1: CGPoint(x: 288.9, y: 355.5), control2: CGPoint(x: 293.3, y: 359.0))
        p.addCurve(to: CGPoint(x: 249.4, y: 351.9), control1: CGPoint(x: 284.9, y: 363.0), control2: CGPoint(x: 263.8, y: 363.3))
        p.closeSubpath()
        let box = p.boundingRect
        guard box.width > 0, box.height > 0 else { return p }
        let scale = min(rect.width / box.width, rect.height / box.height) * 0.98
        return p.applying(CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: rect.midX, y: rect.midY))
    }
}
