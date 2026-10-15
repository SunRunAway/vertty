//
//  UITerminalView+FloatingCursor.swift
//  Vhostty
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    /// Where a space-bar drag started and how far it has moved the cursor.
    struct FloatingCursorState {
        var origin: CGPoint?
        var steps = 0
    }

    /// Vhostty: holding the space bar and sliding moves the cursor. The text
    /// UIKit sees here is only the composition, so its own caret has nowhere
    /// to go; instead each cell of horizontal travel presses Left or Right,
    /// which is how the program in the terminal moves its cursor.
    extension UITerminalView {
        open func beginFloatingCursor(at point: CGPoint) {
            floatingCursor = FloatingCursorState(origin: point)
        }

        open func updateFloatingCursor(at point: CGPoint) {
            guard let origin = floatingCursor.origin, let metrics = surface?.size(),
                  metrics.cellWidthPixels > 0 else { return }
            let cellWidth = CGFloat(metrics.cellWidthPixels) / resolvedDisplayScale()
            let target = Int(((point.x - origin.x) / cellWidth).rounded(.towardZero))
            while floatingCursor.steps < target {
                sendSyntheticKey(usage: 0x4F)
                floatingCursor.steps += 1
            }
            while floatingCursor.steps > target {
                sendSyntheticKey(usage: 0x50)
                floatingCursor.steps -= 1
            }
        }

        open func endFloatingCursor() {
            floatingCursor = FloatingCursorState()
        }
    }
#endif
