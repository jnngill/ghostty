# Native Windows port (unofficial, AI-written)

> [!IMPORTANT]
> **The code on this branch that adds native Windows support was written by
> Claude, an AI model made by Anthropic, using Claude Code.** James Gill
> ([@jnngill](https://github.com/jnngill)) directed the work and published
> it. It is an unofficial fork: it is not affiliated with, reviewed by, or
> endorsed by the Ghostty project or its maintainers.

## What Claude changed

All Windows-specific changes on the `windows-native` branch, beyond upstream
Ghostty, were written by Claude:

- `src/apprt/win32/` and `src/apprt/win32.zig`: a new native Win32
  application runtime (windows, tabs, splits, input, IME, clipboard,
  scrollbar, DPI, dark mode, notifications).
- `pkg/opengl/wgl.zig` and the Windows path in `src/renderer/OpenGL.zig`
  and `src/renderer/opengl/`: WGL context creation and direct presentation
  to the window.
- Smaller fixes so the rest of Ghostty builds and runs natively on Windows,
  in `src/build/`, `src/os/`, `src/termio/Exec.zig`, `src/quirks_memset.zig`,
  `src/config/Config.zig`, `src/apprt/` and `dist/windows/ghostty.manifest`.

Commits that Claude wrote include a
`Co-Authored-By: Claude <noreply@anthropic.com>` trailer.

## Status

Tested by hand on Windows 11 (build 26200), and the Zig test suite passes on
native Windows. Working: rendering, input, tabs, splits, the scrollbar,
unfocused-split dimming, the clipboard, multiple windows, and a portable
release build.

Known gaps:

- Transparent backgrounds (`background-opacity`) and Mica are not supported.
- Desktop notifications are implemented, but Windows' built-in ConPTY drops
  OSC 9/777 escape sequences, so they never reach Ghostty. Other sequences
  ConPTY doesn't understand may also be dropped.
- The terminal inspector and single-instance launching are not implemented.
- There is no installer.

## Building

Requires [Zig 0.16.0](https://ziglang.org/download/) and the Windows SDK
(MSVC toolchain).

```
zig build -Doptimize=ReleaseFast
zig-out\bin\ghostty.exe
```

`zig-out` (the `bin` and `share` folders) is a portable install.
