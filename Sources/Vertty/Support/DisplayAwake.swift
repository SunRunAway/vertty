import AppKit
import IOKit.pwr_mgt

/// "Don't Let the Display Turn Off": while tasks run, hold a display-sleep assertion
/// (like `caffeinate -d`). No authorization needed. Off unless the marker file exists.
final class DisplayAwake {
    private let store: AppStore
    private var timer: Timer?
    private var assertion: IOPMAssertionID?
    static var enabledMarker: URL { AppPaths.support.appendingPathComponent("display-awake") }
    var enabled: Bool { FileManager.default.fileExists(atPath: Self.enabledMarker.path) }
    var holding: Bool { assertion != nil }
    init(store: AppStore) { self.store = store }

    func start() {
        guard enabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
        tick()
    }
    func setEnabled(_ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: Self.enabledMarker.path, contents: Data())
            start()
        } else {
            try? FileManager.default.removeItem(at: Self.enabledMarker)
            stop()
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        release()
    }
    private func tick() {
        if store.workingAgentCount > 0 {
            guard assertion == nil else { return }
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Vertty tasks are running" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else {
            release()
        }
    }
    private func release() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }
}
