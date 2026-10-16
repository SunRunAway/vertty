import CoreServices
import Foundation

/// Events are hints to rescan, including dropped events and root changes.
/// Confined to the main queue. Ignore our own SQLite WAL bookkeeping.
final class HistoryWatcher {
    private var stream: FSEventStreamRef?
    private var codexSources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private let paths: [String]
    private let changed: () -> Void

    init(paths: [URL], changed: @escaping () -> Void) {
        self.changed = changed
        self.paths = paths.map { Self.canonicalPath($0.path) }
        // An existing parent also observes creation of a missing data directory.
        let roots = Set(paths.map { path -> String in
            var root = URL(fileURLWithPath: Self.canonicalPath(path.path)).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: root.path), root.path != "/" {
                root.deleteLastPathComponent()
            }
            return root.path
        })
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<HistoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            for i in 0..<count where watcher.relevant(names[i], flags: flags[i]) {
                watcher.schedule()
                break
            }
        }, &context, Array(roots) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        watchCodexFiles()
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        guard path != "/" else { return path }
        return canonicalPath(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    private func relevant(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        if flags & FSEventStreamEventFlags(rescan) != 0 { return true }
        for (index, root) in paths.enumerated() {
            if path == root || root.hasPrefix(path + "/") { return true }
            guard path.hasPrefix(root + "/") else { continue }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { return true }
            if index == 0 { return path.hasSuffix(".jsonl") }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            return url.deletingLastPathComponent().path == root && name.hasPrefix("state_")
                && (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal"))
        }
        return false
    }

    /// FSEvents may defer SQLite events until its long-lived writer closes.
    /// Vnode write notifications cover committed WAL updates while it stays open.
    private func watchCodexFiles() {
        guard paths.count > 1 else { return }
        let home = paths[1]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let files = [home] + names.filter {
            $0.hasPrefix("state_") && ($0.hasSuffix(".sqlite") || $0.hasSuffix(".sqlite-wal"))
        }.map { home + "/" + $0 }
        for path in files where codexSources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.intersection([.delete, .rename]).isEmpty {
                    self.codexSources.removeValue(forKey: path)?.cancel()
                }
                let previous = Set(self.codexSources.keys)
                self.watchCodexFiles()
                if path != home || previous != Set(self.codexSources.keys) { self.schedule() }
            }
            source.setCancelHandler { close(fd) }
            codexSources[path] = source
            source.resume()
        }
    }

    private func schedule() {
        watchCodexFiles()
        // Bounded coalescing: continuous output must not postpone refresh forever.
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.changed()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit {
        pending?.cancel()
        for source in codexSources.values { source.cancel() }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
