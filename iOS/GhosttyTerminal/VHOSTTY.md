# Vendored GhosttyTerminal

From [libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT, see
LICENSE) at d403978c66870baa422709d1dde385730a4bdaef (tag 2.2.2026101301):
`Sources/GhosttyKit` and `Sources/GhosttyTerminal`, with the prebuilt
GhosttyKit.xcframework from that release. Vhostty's changes:

- `InMemoryTerminalSession` feeds the surface with
  `ghostty_surface_write_buffer_replay`: the output is a mirror of a terminal
  the computer already answers, so queries in it are never answered here.
- `UITerminalView.onWillInput` (through `TerminalSurfaceCoordinator` and
  `TerminalSurface`) runs before every key press and paste, so the client can
  align the session's size before the input.
- The input accessory bar has `shiftTab` and `ctrlC` keys, and
  `UITerminalView.inputAccessoryShowsDismissKey` pins a key that hides the
  software keyboard to the bar's trailing edge, outside the scrolling keys.
