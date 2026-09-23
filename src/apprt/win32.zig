//! Native Win32 application runtime.
//!
//! Each top-level `Window` hosts a single child `Surface` window that the
//! renderer draws into directly via WGL. All UI work happens on the main
//! thread's Win32 message loop.

// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

// The exported API, custom for the apprt.
pub const Window = @import("win32/Window.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("win32/key.zig");
}
