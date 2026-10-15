# Manual installation

[简体中文](manual-installation.zh-CN.md) · [Back to README](../README.md)

For Apple Silicon Macs running macOS 14 or later:

1. Download `Vhostty.zip` from the latest [Release](https://github.com/SunRunAway/vhostty/releases/latest).
2. Unzip it and move `Vhostty.app` to `/Applications`.
3. Open Vhostty.

The app isn't notarized by Apple. If macOS blocks it, go to System Settings → Privacy & Security → "Open Anyway", or run:

```bash
xattr -dr com.apple.quarantine /Applications/Vhostty.app
```

To update, quit Vhostty and replace it with the app from the latest release.
