//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        // A wakeup on the main thread comes from inside a tick or a C call
        // the main thread made; it ticks inline, as it always has.
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller.handleWakeup() }
            return
        }
        guard controller.wakeupGate.claim() else { return }
        DispatchQueue.main.async {
            controller.wakeupGate.release()
            MainActor.assumeIsolated { controller.handleWakeup() }
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s,
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        guard Thread.isMainThread else {
            terminalRunOnMain { bridge.handleAction(action) }
            return false
        }
        return MainActor.assumeIsolated {
            bridge.handleAction(action)
            // Core spawns /usr/bin/open for an open_url reported unhandled,
            // so a host delegate that took the URL is reported as handling
            // it. Both open_url emitters run on the main thread.
            return action.tag == GHOSTTY_ACTION_OPEN_URL
                && bridge.delegate is any TerminalSurfaceOpenURLDelegate
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool,
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    /// A program wrote the clipboard (OSC 52), or a copy binding did.
    ///
    /// `confirm` is ghostty's `clipboard-write = ask`: the write must not
    /// land until the host has asked. That goes through the same
    /// confirmation delegate as a protected read; a host without one denies
    /// it, as it does the read. The default configuration allows writes
    /// outright, and those land immediately.
    ///
    /// Writes one or more MIME-typed representations to the system
    /// pasteboard. `ghostty_clipboard_content_s` is binary-safe with an
    /// explicit `len` and is **not** guaranteed NUL-terminated, so every
    /// representation must be decoded length-bounded rather than via
    /// `String(cString:)` — a NUL-terminated read here would compile clean
    /// and read past the end of the buffer.
    static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool,
    ) {
        // The selection clipboard is advertised (`supports_selection_clipboard`)
        // so that `copy-on-select` writes there and not to the one pasteboard
        // the user has — otherwise every drag, and every double-click a tap
        // lands within ghostty's click interval, would replace it. Nothing
        // exposes a primary selection, so those writes go nowhere.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }

        let payloads = copyClipboardContents(contents, count: contentsLen)
        guard !payloads.isEmpty else { return }

        TerminalDebugLog.log(
            .input,
            "clipboard write count=\(payloads.count) mimes=\(payloads.map(\.mime).joined(separator: ",")) confirm=\(confirm)",
        )

        guard confirm else {
            terminalRunOnMain { setPasteboardString(payloads) }
            return
        }
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let text = firstTextRepresentation(in: payloads) ?? ""
        terminalRunOnMain {
            bridge.handleClipboardConfirmation(contents: text, kind: .osc52Write) { allowed in
                TerminalDebugLog.log(
                    .input,
                    allowed ? "clipboard write allowed" : "clipboard write denied",
                )
                guard allowed else { return }
                setPasteboardString(payloads)
            }
        }
    }

    @MainActor
    private static func setPasteboardString(_ payloads: [TerminalClipboardContent]) {
        #if canImport(UIKit)
            if let text = payloads.first(where: { isTextLikeMime($0.mime) }) {
                UIPasteboard.general.string = String(decoding: text.data, as: UTF8.self)
            }
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for payload in payloads {
                if isTextLikeMime(payload.mime) {
                    pasteboard.setString(String(decoding: payload.data, as: UTF8.self), forType: .string)
                } else {
                    pasteboard.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.mime))
                }
            }
        #endif
    }

    /// Reads the system pasteboard on behalf of a clipboard-read request (a
    /// keybound paste or an OSC 52 read). Returns whether the read started;
    /// libghostty asks `confirmReadClipboard` on its own when the request's
    /// type needs the host's permission.
    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        statePtr: UnsafeMutableRawPointer?,
    ) -> Bool {
        guard let userdata, let statePtr else { return false }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return false }

        // Text and file URLs only, through the shared reader: a file copied
        // in Finder or Files pastes as its escaped path, not its display
        // name. This also serves a program's OSC 52 read, which must not
        // write files as a side effect; a host paste that finds image or
        // document data materialises it itself
        // (`UITerminalView.pasteFromPasteboard`).
        guard let string = TerminalPasteboardContent.text(), !string.isEmpty else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return false
        }
        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))",
        )
        string.withCString { ghostty_surface_complete_clipboard_request(surface, $0, statePtr, false) }
        return true
    }

    /// libghostty determined the pending read needs the host's explicit
    /// permission (OSC 52 / Kitty clipboard protocol) before it can reach
    /// the requesting program. `confirm`'s contents are only borrowed for
    /// this call — copy everything out before any hop or async work, per
    /// the header's doc comment on `ghostty_runtime_confirm_read_clipboard_cb`.
    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        statePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e,
    ) {
        guard let userdata, let string, let statePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        let text = String(cString: string)
        let contents = [TerminalClipboardContent(mime: "text/plain", data: Data(text.utf8))]
        let available: [String] = []

        // An unanswered request hangs the requesting program, so a kind the
        // host's confirmation can't describe is denied outright.
        guard let kind = TerminalClipboardRequestKind(request) else {
            TerminalDebugLog.log(
                .input,
                "clipboard confirm denied: unrecognized request kind=\(request.rawValue)",
            )
            // Round-tripped through a bit pattern, not captured directly:
            // a raw pointer captured as-is by this main-actor-crossing
            // closure trips Swift 6's sending-risks-data-race check.
            let stateAddress = UInt(bitPattern: statePtr)
            terminalRunOnMain {
                guard let surface = bridge.rawSurface,
                      let statePtr = UnsafeMutableRawPointer(bitPattern: stateAddress)
                else { return }
                ghostty_surface_complete_clipboard_request(surface, "", statePtr, true)
            }
            return
        }

        TerminalDebugLog.log(
            .input,
            "clipboard paste confirm request=\(request.rawValue) bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))",
        )

        // Registered synchronously, before the hop to main: a surface
        // teardown racing this callback must be able to find and deny this
        // request the moment it's observable, not only after the hop lands.
        let token = bridge.registerPendingClipboardRequest(statePtr)

        terminalRunOnMain {
            bridge.handleClipboardConfirmation(contents: text, kind: kind) { allowed in
                token.resolve(allowed, contents: contents, available: available)
            }
        }
    }
}

// MARK: - C interop helpers

private func isTextLikeMime(_ mime: String) -> Bool {
    mime == "text/plain" || mime.hasPrefix("text/plain;")
}

private func firstTextRepresentation(in contents: [TerminalClipboardContent]) -> String? {
    guard let chosen = contents.first(where: { isTextLikeMime($0.mime) }) ?? contents.first else {
        return nil
    }
    return String(decoding: chosen.data, as: UTF8.self)
}

private func copyClipboardContents(
    _ ptr: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
) -> [TerminalClipboardContent] {
    guard let ptr, count > 0 else { return [] }
    let buffer = UnsafeBufferPointer(start: ptr, count: count)
    return buffer.compactMap { item in
        guard let mimePtr = item.mime else { return nil }
        let mime = String(cString: mimePtr)
        guard let dataPtr = item.data else {
            return TerminalClipboardContent(mime: mime, data: Data())
        }
        return TerminalClipboardContent(mime: mime, data: Data(String(cString: dataPtr).utf8))
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s,
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool,
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool,
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm,
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    statePtr: UnsafeMutableRawPointer?,
) -> Bool {
    TerminalCallbacks.readClipboard(userdata: userdata, clipboard: clipboard, statePtr: statePtr)
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    statePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e,
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        string: string,
        statePtr: statePtr,
        request: request,
    )
}
