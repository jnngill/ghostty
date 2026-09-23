/// The Win32 application. This owns the message loop and the lifetime of
/// all windows. Everything here runs on the main thread unless noted.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");

const c = @import("c.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

/// Posted to the message window to tick the core app. See `wakeup`.
const WM_APP_WAKEUP = c.WM_APP + 1;

/// Posted to the message window to quit or close all windows from the
/// message loop rather than from within a core callback.
const WM_APP_QUIT = c.WM_APP + 3;
const WM_APP_CLOSE_ALL = c.WM_APP + 4;

/// Callback message for our notification area (tray) icon.
const WM_APP_TRAY = c.WM_APP + 5;

/// Timer ID used for `quit-after-last-window-closed-delay`.
const quit_timer_id = 1;

core_app: *CoreApp,

/// The configuration for the app. This is owned by this structure.
/// The core reads keybinds from this for app-level key events.
config: Config,

hinstance: c.HINSTANCE,

/// A message-only window used to receive wakeups and timers that aren't
/// associated with any visible window.
msg_hwnd: c.HWND,

/// All open windows.
windows: std.ArrayList(*Window) = .empty,

/// Set when a wakeup message is already queued so that we don't flood
/// the message queue from other threads.
wakeup_pending: std.atomic.Value(bool) = .init(false),

/// Set once we've begun quitting so that we don't re-enter.
quitting: bool = false,

/// The system light/dark preference.
color_scheme: apprt.ColorScheme = .dark,

/// Whether our notification area icon (used to show desktop
/// notifications) has been added.
tray_added: bool = false,

/// The surface that sent the most recent desktop notification, so that
/// clicking the notification can bring it forward. May be stale; always
/// validate against the core's surface list before use.
notify_surface: ?*CoreSurface = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;
    const alloc = core_app.alloc;

    // Per-monitor v2 DPI awareness gives us physical pixels everywhere and
    // WM_DPICHANGED when moving between monitors. This can fail if the
    // manifest already set it, which is fine.
    _ = c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    var config = Config.load(alloc) catch |err| err: {
        log.err("error loading config, using defaults err={}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.finalize();
        break :err def;
    };
    errdefer config.deinit();

    const hinstance = c.GetModuleHandleW(null) orelse return error.Win32Error;
    try registerClasses(hinstance);

    const msg_hwnd = c.CreateWindowExW(
        0,
        msg_class,
        c.L(""),
        0,
        0,
        0,
        0,
        0,
        c.HWND_MESSAGE,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer _ = c.DestroyWindow(msg_hwnd);

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .msg_hwnd = msg_hwnd,
        .color_scheme = systemColorScheme(),
    };
    _ = c.SetWindowLongPtrW(msg_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Apply the initial config to the core app. This also triggers the
    // config_change action for the app.
    try core_app.updateConfig(self, &self.config);

    // Let the core know the system color scheme so that conditional
    // config (e.g. `theme = light:...,dark:...`) applies.
    core_app.colorSchemeEvent(self, self.color_scheme) catch |err| {
        log.warn("error setting initial color scheme err={}", .{err});
    };
}

pub fn run(self: *App) !void {
    if (self.config.@"initial-window") {
        _ = try self.newWindow(null);
    }

    var msg: c.MSG = undefined;
    while (true) {
        const rc = c.GetMessageW(&msg, null, 0, 0);
        if (rc == 0) break; // WM_QUIT
        if (rc == -1) return error.Win32Error;
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    const alloc = self.core_app.alloc;
    if (self.tray_added) {
        _ = c.Shell_NotifyIconW(c.NIM_DELETE, &.{ .hWnd = self.msg_hwnd, .uID = 1 });
    }
    self.closeAllWindowsNow();
    self.windows.deinit(alloc);
    _ = c.DestroyWindow(self.msg_hwnd);
    self.config.deinit();
}

/// Called by CoreApp to wake up the event loop. This may be called
/// from any thread.
pub fn wakeup(self: *App) void {
    if (self.wakeup_pending.swap(true, .acq_rel)) return;
    _ = c.PostMessageW(self.msg_hwnd, WM_APP_WAKEUP, 0, 0);
}

fn tick(self: *App) void {
    self.wakeup_pending.store(false, .release);
    self.core_app.tick(self) catch |err| {
        log.err("error in app tick err={}", .{err});
    };
}

/// Only `macOS` supports keyboard layout detection for option-as-alt.
pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
    _ = self;
    return .unknown;
}

pub fn redrawInspector(_: *App, _: *Surface) void {}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return false;
}

/// Create a new top-level window with a single surface.
pub fn newWindow(self: *App, parent: ?*CoreSurface) !*Window {
    const alloc = self.core_app.alloc;
    const window = try Window.create(self, parent);
    errdefer window.destroy();
    try self.windows.append(alloc, window);
    return window;
}

/// Called by a window as it is destroyed.
pub fn removeWindow(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.orderedRemove(i);
            break;
        }
    }
}

/// The most recently focused window, if any.
fn activeWindow(self: *App) ?*Window {
    if (self.core_app.focusedSurface()) |core| {
        for (self.windows.items) |w| {
            if (w == core.rt_surface.window) return w;
        }
    }
    if (self.windows.items.len == 0) return null;
    return self.windows.items[self.windows.items.len - 1];
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        // Destructive app actions run on the next message loop turn since
        // we may be inside a core surface callback right now.
        .quit => _ = c.PostMessageW(self.msg_hwnd, WM_APP_QUIT, 0, 0),
        .close_all_windows => _ = c.PostMessageW(self.msg_hwnd, WM_APP_CLOSE_ALL, 0, 0),

        .new_window => _ = try self.newWindow(switch (target) {
            .app => null,
            .surface => |v| v,
        }),

        .close_window => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.requestClose(),
        },

        .new_tab => switch (target) {
            .app => if (self.activeWindow()) |w| {
                try w.newTab(w.activeTab().focused.core());
            } else {
                _ = try self.newWindow(null);
            },
            .surface => |v| try v.rt_surface.window.newTab(v),
        },

        .close_tab => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.requestCloseTab(v.rt_surface, value),
        },

        .goto_tab => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.gotoTab(value),
        },

        .move_tab => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.moveTab(value.amount),
        },

        .new_split => switch (target) {
            .app => return false,
            .surface => |v| try v.rt_surface.window.newSplit(v.rt_surface, value),
        },

        .goto_split => switch (target) {
            .app => return false,
            .surface => |v| return try v.rt_surface.window.gotoSplit(v.rt_surface, value),
        },

        .resize_split => switch (target) {
            .app => return false,
            .surface => |v| return try v.rt_surface.window.resizeSplit(v.rt_surface, value),
        },

        .equalize_splits => switch (target) {
            .app => return false,
            .surface => |v| return try v.rt_surface.window.equalizeSplits(v.rt_surface),
        },

        .toggle_split_zoom => switch (target) {
            .app => return false,
            .surface => |v| return v.rt_surface.window.toggleSplitZoom(v.rt_surface),
        },

        .quit_timer => switch (value) {
            .start => self.startQuitTimer(),
            .stop => _ = c.KillTimer(self.msg_hwnd, quit_timer_id),
        },

        .config_change => switch (target) {
            // The app config is cloned since the caller owns it.
            .app => if (value.config.clone(self.core_app.alloc)) |config| {
                self.config.deinit();
                self.config = config;
                for (self.windows.items) |w| w.syncAppearance();
            } else |err| {
                log.err("error updating app config err={}", .{err});
            },

            .surface => |v| v.rt_surface.window.syncAppearance(),
        },

        .reload_config => try self.reloadConfig(target, value),

        .open_config => return self.openConfig(),

        .open_url => try openUrl(value.url),

        .set_title, .set_window_title => switch (target) {
            .app => return false,
            .surface => |v| try v.rt_surface.setTitle(value.title),
        },

        .mouse_shape => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseShape(value),
        },

        .scrollbar => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setScrollbar(value),
        },

        .mouse_visibility => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.setMouseVisibility(value == .visible),
        },

        .toggle_fullscreen => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.toggleFullscreen(),
        },

        .toggle_maximize => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.toggleMaximize(),
        },

        .initial_size => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.setInitialSize(value.width, value.height),
        },

        .size_limit => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.size_limit = value,
        },

        .desktop_notification => switch (target) {
            .app => self.showNotification(null, value),
            .surface => |v| self.showNotification(v, value),
        },

        .ring_bell => switch (target) {
            .app => _ = c.MessageBeep(c.MB_BEEP_DEFAULT),
            .surface => |v| v.rt_surface.window.ringBell(),
        },

        .present_terminal => switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window.present(v.rt_surface),
        },

        .goto_window => {
            const n = self.windows.items.len;
            if (n <= 1) return false;
            const current = self.activeWindow() orelse return false;
            const i = for (self.windows.items, 0..) |w, i| {
                if (w == current) break i;
            } else 0;
            const next = switch (value) {
                .next => (i + 1) % n,
                .previous => (i + n - 1) % n,
            };
            self.windows.items[next].present(null);
        },

        // The WGL renderer presents directly to the window, so there is
        // nothing for us to do to render.
        .render => {},

        // Everything else is unimplemented for now.
        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }

    return true;
}

fn quit(self: *App) void {
    if (self.quitting) return;
    if (self.core_app.needsConfirmQuit() and !confirm(
        null,
        "Quit Ghostty?",
        "All terminal sessions will be terminated.",
    )) return;

    self.quitting = true;
    self.closeAllWindowsNow();
    c.PostQuitMessage(0);
}

fn closeAllWindows(self: *App) void {
    if (self.core_app.needsConfirmQuit() and !confirm(
        null,
        "Close all windows?",
        "All terminal sessions will be terminated.",
    )) return;
    self.closeAllWindowsNow();
}

fn closeAllWindowsNow(self: *App) void {
    // Destroying a window removes it from the list, so iterate on a copy.
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
}

fn startQuitTimer(self: *App) void {
    if (!self.config.@"quit-after-last-window-closed") return;
    if (self.core_app.surfaces.items.len > 0) return;

    if (self.config.@"quit-after-last-window-closed-delay") |delay| {
        const ms = std.math.cast(c.UINT, delay.asMilliseconds()) orelse
            std.math.maxInt(c.UINT);
        _ = c.SetTimer(self.msg_hwnd, quit_timer_id, ms, null);
        return;
    }

    self.quitting = true;
    c.PostQuitMessage(0);
}

fn reloadConfig(
    self: *App,
    target: apprt.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    const alloc = self.core_app.alloc;
    var loaded: ?Config = if (opts.soft) null else try Config.load(alloc);
    defer if (loaded) |*v| v.deinit();
    const config: *const Config = if (loaded) |*v| v else &self.config;

    switch (target) {
        .app => try self.core_app.updateConfig(self, config),
        .surface => |core| try core.updateConfig(config),
    }
}

fn openConfig(self: *App) bool {
    const alloc = self.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("error getting config file path err={}", .{err});
        return false;
    };
    defer alloc.free(path);

    openUrl(path) catch |err| {
        log.warn("error opening config file err={}", .{err});
        return false;
    };
    return true;
}

fn openUrl(url: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const url_w = try c.utf16(fba.allocator(), url);
    const rc = @intFromPtr(c.ShellExecuteW(
        null,
        c.L("open"),
        url_w,
        null,
        null,
        c.SW_SHOWNORMAL,
    ));
    // Per the docs, values <= 32 are errors.
    if (rc <= 32) {
        log.warn("ShellExecuteW failed url={s} rc={}", .{ url, rc });
        return error.OpenFailed;
    }
}

/// Show a desktop notification. Windows turns notification area
/// balloons into native toast notifications.
fn showNotification(
    self: *App,
    surface: ?*CoreSurface,
    value: apprt.action.DesktopNotification,
) void {
    // Don't notify about the terminal the user is already looking at.
    if (surface) |s| {
        const rt = s.rt_surface;
        if (c.GetForegroundWindow() == rt.window.hwnd and c.GetFocus() == rt.hwnd) return;
    }

    const icon = c.LoadIconW(self.hinstance, 1) orelse c.LoadIconW(null, c.IDI_APPLICATION);
    if (!self.tray_added) {
        var add: c.NOTIFYICONDATAW = .{
            .hWnd = self.msg_hwnd,
            .uID = 1,
            .uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP | c.NIF_SHOWTIP,
            .uCallbackMessage = WM_APP_TRAY,
            .hIcon = icon,
        };
        c.copyUtf16(&add.szTip, "Ghostty");
        if (c.Shell_NotifyIconW(c.NIM_ADD, &add) == 0) {
            log.warn("failed to add notification icon", .{});
            return;
        }
        add.uVersion = c.NOTIFYICON_VERSION_4;
        _ = c.Shell_NotifyIconW(c.NIM_SETVERSION, &add);
        self.tray_added = true;
    }

    var info: c.NOTIFYICONDATAW = .{
        .hWnd = self.msg_hwnd,
        .uID = 1,
        .uFlags = c.NIF_INFO,
        .dwInfoFlags = c.NIIF_USER | c.NIIF_LARGE_ICON,
        .hBalloonIcon = icon,
    };
    c.copyUtf16(&info.szInfoTitle, if (value.title.len > 0) value.title else "Ghostty");
    c.copyUtf16(&info.szInfo, value.body);
    if (c.Shell_NotifyIconW(c.NIM_MODIFY, &info) == 0) {
        log.warn("failed to show desktop notification", .{});
        return;
    }
    self.notify_surface = surface;
}

/// Bring forward the surface that sent the last notification, if it
/// still exists.
fn notificationClicked(self: *App) void {
    const target = self.notify_surface orelse return;
    self.notify_surface = null;
    for (self.core_app.surfaces.items) |s| {
        if (&s.core_surface == target) {
            s.window.present(s);
            return;
        }
    }
}

/// Called when a window receives WM_SETTINGCHANGE.
pub fn settingChanged(self: *App, lparam: c.LPARAM) void {
    // The system theme change is broadcast as "ImmersiveColorSet".
    if (lparam == 0) return;
    const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (!std.mem.eql(u16, std.mem.span(name), c.L("ImmersiveColorSet"))) return;

    const scheme = systemColorScheme();
    if (scheme == self.color_scheme) return;
    self.color_scheme = scheme;

    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.warn("error updating color scheme err={}", .{err});
    };
    for (self.core_app.surfaces.items) |s| {
        s.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.warn("error updating surface color scheme err={}", .{err});
        };
    }
    for (self.windows.items) |w| w.syncAppearance();
}

/// Read the user's app light/dark preference from the registry.
fn systemColorScheme() apprt.ColorScheme {
    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const rc = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        c.L("AppsUseLightTheme"),
        c.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    if (rc != 0) return .dark;
    return if (value == 0) .dark else .light;
}

/// Show a modal yes/no confirmation dialog. Returns true if confirmed.
pub fn confirm(parent: ?c.HWND, comptime title: []const u8, comptime body: []const u8) bool {
    return c.MessageBoxW(
        parent,
        c.L(body),
        c.L(title),
        c.MB_OKCANCEL | c.MB_ICONWARNING,
    ) == c.IDOK;
}

// Window classes ------------------------------------------------------------

pub const msg_class = c.L("GhosttyMessageWindow");

fn registerClasses(hinstance: c.HINSTANCE) !void {
    const icon = c.LoadIconW(hinstance, 1) orelse c.LoadIconW(null, c.IDI_APPLICATION);

    if (c.RegisterClassExW(&.{
        .lpfnWndProc = msgWndProc,
        .hInstance = hinstance,
        .lpszClassName = msg_class,
    }) == 0) return error.Win32Error;

    if (c.RegisterClassExW(&.{
        .style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_DBLCLKS,
        .lpfnWndProc = Window.wndProc,
        .hInstance = hinstance,
        .hIcon = icon,
        .hIconSm = icon,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = Window.class_name,
    }) == 0) return error.Win32Error;

    if (c.RegisterClassExW(&.{
        .lpfnWndProc = Surface.dimWndProc,
        .hInstance = hinstance,
        .lpszClassName = Surface.dim_class_name,
    }) == 0) return error.Win32Error;

    // CS_OWNDC is required: the renderer thread holds this window's DC
    // for the lifetime of its WGL context.
    if (c.RegisterClassExW(&.{
        .style = c.CS_OWNDC | c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = hinstance,
        .lpszClassName = Surface.class_name,
    }) == 0) return error.Win32Error;
}

fn msgWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    const self: *App = if (ptr != 0) @ptrFromInt(ptr) else return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_APP_WAKEUP => {
            self.tick();
            return 0;
        },

        WM_APP_QUIT => {
            self.quit();
            return 0;
        },

        WM_APP_CLOSE_ALL => {
            self.closeAllWindows();
            return 0;
        },

        WM_APP_TRAY => {
            // With NOTIFYICON_VERSION_4 the event is in the low word.
            switch (c.loword(lparam)) {
                c.NIN_BALLOONUSERCLICK, c.WM_LBUTTONUP => self.notificationClicked(),
                else => {},
            }
            return 0;
        },

        c.WM_TIMER => if (wparam == quit_timer_id) {
            _ = c.KillTimer(hwnd, quit_timer_id);
            if (self.core_app.surfaces.items.len == 0) {
                self.quitting = true;
                c.PostQuitMessage(0);
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
