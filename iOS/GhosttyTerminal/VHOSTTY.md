# Vendored GhosttyTerminal

From [libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT, see
LICENSE) at d403978c66870baa422709d1dde385730a4bdaef (tag 2.2.2026101301):
`Sources/GhosttyKit` and `Sources/GhosttyTerminal`. The GhosttyKit.xcframework
under them is not libghostty-spm's: `scripts/build-ghostty-ios.sh` builds it
from `vendor/ghostty` and `patches/ghostty-vhostty.patch`, the same Ghostty
as the Mac app, and it isn't checked in. Vhostty's changes:

- Fitted to Ghostty 1.3.1's C API: clipboard reads complete with the text,
  and the process-exit, foreground-pid and tty-name calls are gone (an
  in-memory surface has no process).
- The in-memory backend is the patch's host-managed one (`host_write` /
  `host_resize` in the surface config, `ghostty_surface_write_buffer`): the
  output is a mirror of a terminal the computer already answers, so queries
  in it are never answered here.
- Frames are paced by the system's `CADisplayLink`
  (`TerminalSurfaceCoordinator`), not libghostty-spm's DisplayLink package,
  so the package has no outside dependencies.
- `UITerminalView.onWillInput` (through `TerminalSurfaceCoordinator` and
  `TerminalSurface`) runs before every key press and paste, so the client can
  align the session's size before the input.
- The input accessory bar has `shiftTab` and `ctrlC` keys, shows Esc as the
  text "Esc" rather than a glyph, and
  `UITerminalView.inputAccessoryShowsDismissKey` pins a key that hides the
  software keyboard to the bar's trailing edge, outside the scrolling keys.
