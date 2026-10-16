# 手动安装

[English](manual-installation.md) · [返回 README](../README.zh-CN.md)

适用于 Apple Silicon 的 Mac，macOS 14 及以上：

1. 从最新的 [Release](https://github.com/SunRunAway/vertty/releases/latest) 下载 `Vertty.zip`。
2. 解压，将 `Vertty.app` 移到 `/Applications`。
3. 打开 Vertty。

App 没有经过 Apple 公证。如果 macOS 阻止打开，到「系统设置 → 隐私与安全性」里点「仍要打开」，或者执行：

```bash
xattr -dr com.apple.quarantine /Applications/Vertty.app
```

更新时，退出 Vertty，再用最新 Release 中的 App 替换旧版本。
