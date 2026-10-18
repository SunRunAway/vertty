import UIKit
import os

/// Persistent metadata for a disappearing system paste control. Never reads
/// clipboard or text fields; records no accessibility text or layer contents.
/// View/layer metadata cannot prove that the system actually drew the icon.
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
        // Complete lifecycle/screenshot writes before suspension, not just enqueue them.
        if flush { queue.sync {} }
    }

    static func view(_ view: UIView, depth: Int = 0) -> [String: Any] {
        var result: [String: Any] = [
            "class": NSStringFromClass(type(of: view)),
            "id": String(describing: ObjectIdentifier(view)),
            "frame": NSCoder.string(for: view.frame), "bounds": NSCoder.string(for: view.bounds),
            "hidden": view.isHidden, "alpha": view.alpha,
            "clips": view.clipsToBounds, "interactive": view.isUserInteractionEnabled,
            "inWindow": view.window != nil, "ambiguous": view.hasAmbiguousLayout,
            "layer": layer(view.layer, depth: depth > 0 ? 2 : 0),
        ]
        if let window = view.window {
            result["windowRect"] = NSCoder.string(for: view.convert(view.bounds, to: window))
        }
        if depth > 0 { result["children"] = view.subviews.map { self.view($0, depth: depth - 1) } }
        return result
    }

    private static func layer(_ layer: CALayer, depth: Int) -> [String: Any] {
        var result: [String: Any] = [
            "class": NSStringFromClass(type(of: layer)), "id": String(describing: ObjectIdentifier(layer)),
            "hidden": layer.isHidden, "hasContents": layer.contents != nil,
            "opacity": layer.opacity, "bounds": NSCoder.string(for: layer.bounds),
            "position": NSCoder.string(for: layer.position), "transform": String(describing: layer.transform),
            "clips": layer.masksToBounds, "animationKeys": layer.animationKeys() ?? [],
        ]
        if let presentation = layer.presentation() {
            result["presentation"] = ["opacity": presentation.opacity,
                                      "hidden": presentation.isHidden,
                                      "frame": NSCoder.string(for: presentation.frame)] as [String: Any]
        }
        if depth > 0 { result["children"] = (layer.sublayers ?? []).map { self.layer($0, depth: depth - 1) } }
        return result
    }
}
