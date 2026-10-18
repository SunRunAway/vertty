import UIKit
import os

/// Sparse lifecycle and paste-result metadata. Never reads clipboard or text
/// fields; stores no image data. Child geometry helps distinguish a retained
/// rendered control from an empty one, but does not prove the icon is visible.
enum PasteDiagnostics {
    private static let logger = Logger(subsystem: "dev.vertty", category: "paste-control")
    private static let queue = DispatchQueue(label: "vertty.paste-diagnostics")
    private static let run = UUID().uuidString
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("paste-control.jsonl")
    private static let limit = 2 * 1024 * 1024
    private static var handle: FileHandle?
    private static var size = 0
    private static let format: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    static func record(_ event: String, state: [String: Any] = [:], flush: Bool = false) {
        let time = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            do {
                var entry = state
                entry["event"] = event
                entry["time"] = format.string(from: time)
                entry["uptime"] = uptime
                entry["run"] = run
                entry["pid"] = ProcessInfo.processInfo.processIdentifier
                let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) + Data([10])
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                    }
                    handle = try FileHandle(forWritingTo: url)
                    size = Int(try handle!.seekToEnd())
                }
                if size + data.count > limit {
                    try handle?.close()
                    handle = nil
                    // Current plus three previous files, at most 8 MiB.
                    for index in stride(from: 3, through: 1, by: -1) {
                        let destination = url.appendingPathExtension(String(index))
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        let source = index == 1 ? url : url.appendingPathExtension(String(index - 1))
                        if FileManager.default.fileExists(atPath: source.path) {
                            try FileManager.default.moveItem(at: source, to: destination)
                        }
                    }
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    handle = try FileHandle(forWritingTo: url)
                    size = 0
                }
                try handle?.write(contentsOf: data)
                size += data.count
                if flush { try handle?.synchronize() }
            } catch {
                logger.error("Cannot write paste diagnostics: \(String(describing: error), privacy: .public)")
                try? handle?.close()
                handle = nil
            }
        }
        // Complete lifecycle writes before suspension, not just enqueue them.
        if flush { queue.sync {} }
    }

    static func view(_ view: UIView) -> [String: Any] {
        [
            "id": String(describing: ObjectIdentifier(view)),
            "bounds": NSCoder.string(for: view.bounds),
            "hidden": view.isHidden, "inWindow": view.window != nil,
            // Only the immediate rendering views; no recursive hierarchy,
            // ancestor, animation or presentation-layer inspection.
            "children": view.subviews.map { child in
                ["id": String(describing: ObjectIdentifier(child)),
                 "bounds": NSCoder.string(for: child.bounds),
                 "layer": ["hasContents": child.layer.contents != nil]] as [String: Any]
            },
        ]
    }
}
