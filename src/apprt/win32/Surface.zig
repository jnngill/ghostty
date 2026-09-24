/// A terminal surface. This is a child window that the renderer draws
/// into directly via WGL and that receives keyboard and mouse input.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const key = @import("key.zig");
const App = @import("App.zig");
const Scrollbar = @import("Scrollbar.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_surface);

pub const class_name = c.L("GhosttySurface");

app: *App,
window: *Window,
hwnd: c.HWND,
core_surface: CoreSurface,

/// Reference count. Split trees hold references; the surface is
/// destroyed when the last reference is released.
ref_count: u32 = 1,

/// Whether the surface is currently shown.
visible: bool = true,

/// A translucent, click-through overlay used to dim this surface when
/// it is an unfocused split. Created lazily.
dim_hwnd: ?c.HWND = null,

/// The overlay scrollbar.
scrollbar: Scrollbar,

/// Whether core_surface has been initialized.
core_initialized: bool = false,

content_scale: apprt.ContentScale,
size: apprt.SurfaceSize,
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },

/// The title of the surface as UTF-8, owned.
title: ?[:0]const u8 = null,

/// The cursor to show over the surface.
cursor: ?c.HCURSOR,
cursor_visible: bool = true,

/// Whether we asked for WM_MOUSELEAVE.
tracking_mouse: bool = false,

/// A high surrogate from a WM_CHAR received outside of a key event
/// (e.g. IME commit), waiting for its low surrogate.
pending_high_surrogate: ?u16 = null,

/// Create a new surface with a reference count of one.
pub fn create(
    app: *App,
    window: *Window,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(window.hwnd, &rect);

    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        window.hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer _ = c.DestroyWindow(hwnd);

    // Our client area excludes the scrollbar, if any.
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const scale = window.scale();
    self.* = .{
        .app = app,
        .window = window,
        .hwnd = hwnd,
        .core_surface = undefined,
        .content_scale = .{ .x = scale, .y = scale },
        .size = .{
            .width = @intCast(@max(1, client.right - client.left)),
            .height = @intCast(@max(1, client.bottom - client.top)),
        },
        .cursor = c.LoadCursorW(null, c.IDC_IBEAM),
        .scrollbar = .{ .surface = self },
    };
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    errdefer _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);

    // Add ourselves to the list of surfaces on the app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    errdefer self.core_surface.deinit();
    self.core_initialized = true;

    if (parent) |p| {
        // Windows and tabs follow window-inherit-font-size; splits always
        // inherit, like the GTK app.
        const inherit = switch (context) {
            .window, .tab => app.config.@"window-inherit-font-size",
            .split => true,
        };
        if (inherit) {
            self.core_surface.setFontSize(p.font_size) catch |err| {
                log.warn("error inheriting font size err={}", .{err});
            };
        }
    }

    return self;
}

pub fn ref(self: *Surface) *Surface {
    self.ref_count += 1;
    return self;
}

pub fn unref(self: *Surface) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) self.destroy();
}

pub fn eql(a: *const Surface, b: *const Surface) bool {
    return a == b;
}

/// Tear down the surface. Called when the last reference is released.
fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;

    // Detach from the HWND first so no more messages reach us.
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    if (self.core_initialized) {
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
        self.core_initialized = false;
    }

    if (self.title) |v| alloc.free(v);
    if (self.dim_hwnd) |h| _ = c.DestroyWindow(h);
    self.scrollbar.deinit();
    _ = c.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// Called by the core app for any surfaces still alive when it is
/// destroyed. Normally App.terminate destroys all windows first, so this
/// only stops the core surface; the core is iterating its own surface
/// list so we must not call deleteSurface.
pub fn deinit(self: *Surface) void {
    if (!self.core_initialized) return;
    self.core_surface.deinit();
    self.core_initialized = false;
}

// apprt surface interface ---------------------------------------------------

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

/// The window the renderer draws into. See renderer/OpenGL.zig.
pub fn win32Hwnd(self: *const Surface) *anyopaque {
    return self.hwnd;
}

pub fn close(self: *Surface, process_active: bool) void {
    // The core calls this from within its own callbacks, so the window
    // defers the actual teardown to the message loop.
    self.window.requestCloseSurface(self, process_active);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard_type != .standard) return .unsupported;

    // Kitty clipboard writes carry their own contents.
    if (state == .kitty_write) {
        self.completeClipboard(state, .{});
        return .started;
    }

    const alloc = self.app.core_app.alloc;
    const text = readClipboardText(alloc, self.hwnd) catch |err| {
        log.warn("error reading clipboard err={}", .{err});
        return .unavailable;
    };
    defer if (text) |v| alloc.free(v);

    const available: []const []const u8 = if (text != null) &.{"text/plain"} else &.{};
    switch (state) {
        // Paste events only list types.
        .list => self.completeClipboard(state, .{ .available = available }),

        else => {
            const t = text orelse return .unavailable;
            self.completeClipboard(state, .{
                .contents = &.{.{ .mime = "text/plain", .data = t }},
                .available = available,
            });
        },
    }

    return .started;
}

/// Complete a clipboard request, confirming with the user if the core
/// deems it unsafe.
fn completeClipboard(
    self: *Surface,
    state: apprt.ClipboardRequest,
    complete: CoreSurface.CompleteClipboard,
) void {
    self.core_surface.completeClipboardRequest(state, complete) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const ok = App.confirm(
                self.window.hwnd,
                "Warning: Potentially Unsafe Clipboard Access",
                "A program or the pasted text may be trying to do something " ++
                    "unexpected with the clipboard, such as running commands. " ++
                    "Do you want to allow this?",
            );
            if (!ok) {
                self.core_surface.denyClipboardRequest(state);
                return;
            }

            var confirmed = complete;
            confirmed.confirmed = true;
            self.core_surface.completeClipboardRequest(state, confirmed) catch |err2| {
                log.err("error completing clipboard request err={}", .{err2});
            };
        },

        else => log.err("error completing clipboard request err={}", .{err}),
    };
}

pub fn setClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;

    const text: []const u8 = for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) break content.data;
    } else return;

    if (confirm and !App.confirm(
        self.window.hwnd,
        "Allow Clipboard Write?",
        "A program is trying to write to the clipboard. Do you want to allow this?",
    )) return;

    try writeClipboardText(self.app.core_app.alloc, self.hwnd, text);
}

// Actions -------------------------------------------------------------------

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeZ(u8, title);
    if (self.title) |v| alloc.free(v);
    self.title = copy;
    self.window.titleChanged(self);
}

/// Update the scrollbar to reflect the terminal's scroll state.
pub fn setScrollbar(self: *Surface, value: terminal.Scrollbar) void {
    self.scrollbar.setState(value);
}

/// Record the surface's area in the window (after layout), keeping
/// overlays positioned over it.
pub fn setFrame(self: *Surface, rect: c.RECT) void {
    self.scrollbar.setFrame(rect);
}

/// Show or hide the dim overlay for this surface. `rect` is the
/// surface's area in window client coordinates.
pub fn setDimmed(self: *Surface, dimmed: bool, rect: c.RECT) void {
    if (!dimmed) {
        if (self.dim_hwnd) |h| _ = c.ShowWindow(h, c.SW_HIDE);
        return;
    }

    const config = &self.app.config;
    const opacity = std.math.clamp(config.@"unfocused-split-opacity", 0.15, 1);
    if (opacity >= 1) {
        if (self.dim_hwnd) |h| _ = c.ShowWindow(h, c.SW_HIDE);
        return;
    }

    const h = self.dim_hwnd orelse h: {
        const h = c.CreateWindowExW(
            c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE,
            dim_class_name,
            c.L(""),
            c.WS_CHILD | c.WS_DISABLED,
            0,
            0,
            0,
            0,
            self.window.hwnd,
            null,
            self.app.hinstance,
            null,
        ) orelse return;
        _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.dim_hwnd = h;
        break :h h;
    };

    const alpha: u8 = @intFromFloat(@round((1 - opacity) * 255));
    _ = c.SetLayeredWindowAttributes(h, 0, alpha, c.LWA_ALPHA);
    _ = c.SetWindowPos(
        h,
        c.HWND_TOP,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    _ = c.InvalidateRect(h, null, 1);
}

pub const dim_class_name = c.L("GhosttyDim");

/// Window procedure for the dim overlay: it just fills itself with the
/// configured fill color; the layered alpha does the rest.
pub fn dimWndProc(
    hwnd_: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd_, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd_, msg, wparam, lparam);
    const self: *Surface = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd_, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd_, &ps);
            const config = &self.app.config;
            const fill = config.@"unfocused-split-fill" orelse config.background;
            const brush = c.CreateSolidBrush(c.rgb(fill.r, fill.g, fill.b)) orelse return 0;
            defer _ = c.DeleteObject(brush);
            _ = c.FillRect(hdc, &ps.rcPaint, brush);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd_, msg, wparam, lparam),
    }
}

/// Show or hide the surface. Hidden surfaces stop rendering.
pub fn setVisible(self: *Surface, visible: bool) void {
    if (self.visible == visible) return;
    self.visible = visible;
    if (!visible) {
        if (self.dim_hwnd) |h| _ = c.ShowWindow(h, c.SW_HIDE);
        self.scrollbar.hide();
    }
    _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOW else c.SW_HIDE);
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.err("error in occlusion callback err={}", .{err});
    };
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const id: usize = switch (shape) {
        .default, .context_menu, .alias, .copy, .cell, .zoom_in, .zoom_out => c.IDC_ARROW,
        .help => c.IDC_HELP,
        .pointer, .grab, .grabbing => c.IDC_HAND,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .crosshair => c.IDC_CROSS,
        .text, .vertical_text => c.IDC_IBEAM,
        .move, .all_scroll => c.IDC_SIZEALL,
        .no_drop, .not_allowed => c.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => c.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => c.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => c.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => c.IDC_SIZENWSE,
    };
    self.cursor = c.LoadCursorW(null, id);
    self.applyCursor();
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    self.cursor_visible = visible;
    self.applyCursor();
}

fn applyCursor(self: *const Surface) void {
    // Only change the cursor if it's over us; WM_SETCURSOR handles the rest.
    if (self.cursor_pos.x < 0) return;
    _ = c.SetCursor(if (self.cursor_visible) self.cursor else null);
}

pub fn updateContentScale(self: *Surface) void {
    const scale = self.window.scale();
    if (scale == self.content_scale.x) return;
    self.content_scale = .{ .x = scale, .y = scale };
    self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
        log.err("error in content scale callback err={}", .{err});
    };
}

fn updateSize(self: *Surface, width: u32, height: u32) void {
    // Minimized windows report 0x0; keep our last known size.
    if (width == 0 or height == 0) return;
    if (self.size.width == width and self.size.height == height) return;
    self.size = .{ .width = width, .height = height };
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.err("error in size callback err={}", .{err});
    };
}

// Input ---------------------------------------------------------------------

/// Handle a key message. Returns true if the core consumed it.
fn keyEvent(self: *Surface, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
    const vk: u32 = @truncate(wparam);

    // The IME is handling this key.
    if (vk == c.VK_PROCESSKEY) return false;

    const bits: usize = @bitCast(lparam);
    const is_release = msg == c.WM_KEYUP or msg == c.WM_SYSKEYUP;
    const was_down = (bits & (1 << 30)) != 0;
    const action: input.Action = if (is_release)
        .release
    else if (was_down)
        .repeat
    else
        .press;

    // TranslateMessage has already queued any character messages this
    // key produces, so we pull them out now to attach the text to this
    // key event. WM_SYSKEY* sits between the two char ranges.
    var text: key.TextBuffer = .{};
    var composing = false;
    if (!is_release) {
        var next: c.MSG = undefined;
        while (c.PeekMessageW(&next, self.hwnd, c.WM_CHAR, c.WM_DEADCHAR, c.PM_REMOVE) != 0 or
            c.PeekMessageW(&next, self.hwnd, c.WM_SYSCHAR, c.WM_SYSDEADCHAR, c.PM_REMOVE) != 0)
        {
            switch (next.message) {
                c.WM_DEADCHAR, c.WM_SYSDEADCHAR => composing = true,
                else => text.append(@truncate(next.wParam)),
            }
        }
    }

    var utf8_buf: [64]u8 = undefined;
    const utf8 = if (composing) "" else text.utf8(&utf8_buf);

    const mods = key.mods();
    var consumed: input.Mods = .{};
    if (utf8.len > 0 and !(utf8.len == 1 and (utf8[0] < 0x20 or utf8[0] == 0x7F))) {
        consumed.shift = mods.shift;
        if (key.altGr()) {
            consumed.ctrl = true;
            consumed.alt = true;
        }
    }

    const native = key.nativeKeycode(vk, lparam);
    const event: input.KeyEvent = .{
        .action = action,
        .key = key.physicalKey(native),
        .mods = mods,
        .consumed_mods = consumed,
        .composing = composing,
        .utf8 = utf8,
        .unshifted_codepoint = key.unshiftedCodepoint(vk, native),
    };

    const effect = self.core_surface.keyCallback(event) catch |err| {
        log.err("error in key callback err={}", .{err});
        return false;
    };

    return switch (effect) {
        .consumed, .closed => true,
        .ignored => false,
    };
}

/// A character outside of a key event, e.g. from the IME or Alt codes.
fn charEvent(self: *Surface, unit: u16) void {
    var units: [2]u16 = undefined;
    const slice: []const u16 = if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.pending_high_surrogate = unit;
        return;
    } else if (std.unicode.utf16IsLowSurrogate(unit)) slice: {
        const high = self.pending_high_surrogate orelse return;
        self.pending_high_surrogate = null;
        units = .{ high, unit };
        break :slice &units;
    } else slice: {
        // Control characters are delivered with their key events.
        if (unit < 0x20 or unit == 0x7F) return;
        units[0] = unit;
        break :slice units[0..1];
    };

    var buf: [8]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, slice) catch return;
    self.core_surface.textCallback(buf[0..len]) catch |err| {
        log.err("error in text callback err={}", .{err});
    };
}

fn mouseMods(wparam: c.WPARAM) input.Mods {
    var mods = key.mods();
    mods.shift = (wparam & c.MK_SHIFT) != 0;
    mods.ctrl = (wparam & c.MK_CONTROL) != 0;
    return mods;
}

fn mouseButton(
    self: *Surface,
    state: input.MouseButtonState,
    button: input.MouseButton,
    wparam: c.WPARAM,
) void {
    switch (state) {
        .press => {
            // Child windows don't take focus on click by themselves.
            if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
            _ = c.SetCapture(self.hwnd);
        },
        .release => _ = c.ReleaseCapture(),
    }

    const consumed = self.core_surface.mouseButtonCallback(
        state,
        button,
        mouseMods(wparam),
    ) catch |err| err: {
        log.err("error in mouse button callback err={}", .{err});
        break :err true;
    };

    // An unconsumed right press means the core selected the word under
    // the cursor and wants us to show the context menu (it consumes the
    // press instead for other right-click-action values or when the
    // terminal is reporting mouse events).
    if (!consumed and button == .right and state == .press) {
        _ = c.ReleaseCapture();
        var pt: c.POINT = undefined;
        if (c.GetCursorPos(&pt) != 0) self.showContextMenu(pt);
    }
}

/// Context menu commands. Zero is reserved for "no selection".
const MenuCommand = enum(usize) {
    copy = 1,
    paste,
    clear,
    reset,
    split_up,
    split_down,
    split_left,
    split_right,
    close_split,
    new_tab,
    close_tab,
    new_window,
    close_window,
    open_config,
    reload_config,

    fn action(self: MenuCommand) input.Binding.Action {
        return switch (self) {
            .copy => .{ .copy_to_clipboard = .mixed },
            .paste => .paste_from_clipboard,
            .clear => .clear_screen,
            .reset => .reset,
            .split_up => .{ .new_split = .up },
            .split_down => .{ .new_split = .down },
            .split_left => .{ .new_split = .left },
            .split_right => .{ .new_split = .right },
            .close_split => .close_surface,
            .new_tab => .new_tab,
            .close_tab => .{ .close_tab = .this },
            .new_window => .new_window,
            .close_window => .close_window,
            .open_config => .{ .open_config = .os_open },
            .reload_config => .reload_config,
        };
    }
};

/// Show the terminal context menu at the given screen position and run
/// the chosen command. Mirrors the GTK context menu.
fn showContextMenu(self: *Surface, pt: c.POINT) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);

    const Item = struct {
        fn add(m: c.HMENU, cmd: MenuCommand, label: [*:0]const u16, enabled: bool) void {
            _ = c.AppendMenuW(
                m,
                c.MF_STRING | @as(c.UINT, if (enabled) 0 else c.MF_GRAYED),
                @intFromEnum(cmd),
                label,
            );
        }
        fn separator(m: c.HMENU) void {
            _ = c.AppendMenuW(m, c.MF_SEPARATOR, 0, null);
        }
        fn submenu(m: c.HMENU, sub: c.HMENU, label: [*:0]const u16) void {
            _ = c.AppendMenuW(m, c.MF_POPUP, @intFromPtr(sub), label);
        }
    };

    Item.add(menu, .copy, c.L("Copy"), self.core_surface.hasSelection());
    Item.add(menu, .paste, c.L("Paste"), c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0);
    Item.separator(menu);
    Item.add(menu, .clear, c.L("Clear"), true);
    Item.add(menu, .reset, c.L("Reset"), true);
    Item.separator(menu);

    // Submenus are owned by the parent menu once appended, so they're
    // destroyed along with it.
    if (c.CreatePopupMenu()) |sub| {
        Item.add(sub, .split_up, c.L("Split Up"), true);
        Item.add(sub, .split_down, c.L("Split Down"), true);
        Item.add(sub, .split_left, c.L("Split Left"), true);
        Item.add(sub, .split_right, c.L("Split Right"), true);
        Item.separator(sub);
        Item.add(sub, .close_split, c.L("Close Split"), true);
        Item.submenu(menu, sub, c.L("Split"));
    }
    if (c.CreatePopupMenu()) |sub| {
        Item.add(sub, .new_tab, c.L("New Tab"), true);
        Item.add(sub, .close_tab, c.L("Close Tab"), true);
        Item.submenu(menu, sub, c.L("Tab"));
    }
    if (c.CreatePopupMenu()) |sub| {
        Item.add(sub, .new_window, c.L("New Window"), true);
        Item.add(sub, .close_window, c.L("Close Window"), true);
        Item.submenu(menu, sub, c.L("Window"));
    }
    Item.separator(menu);
    if (c.CreatePopupMenu()) |sub| {
        Item.add(sub, .open_config, c.L("Open Configuration"), true);
        Item.add(sub, .reload_config, c.L("Reload Configuration"), true);
        Item.submenu(menu, sub, c.L("Config"));
    }

    const chosen = c.TrackPopupMenu(
        menu,
        c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY,
        pt.x,
        pt.y,
        0,
        self.hwnd,
        null,
    );
    if (chosen <= 0) return;
    const cmd = std.enums.fromInt(MenuCommand, @as(usize, @intCast(chosen))) orelse return;

    _ = self.core_surface.performBindingAction(cmd.action()) catch |err| {
        log.err("error performing context menu action err={}", .{err});
    };
}

fn mouseMove(self: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) void {
    if (!self.tracking_mouse) {
        var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
        self.tracking_mouse = c.TrackMouseEvent(&tme) != 0;
    }

    const pos: apprt.CursorPos = .{
        .x = @floatFromInt(c.xParam(lparam)),
        .y = @floatFromInt(c.yParam(lparam)),
    };

    // Windows can report motion without movement (e.g. after focus
    // changes); ignore those so mouse-hide-while-typing works.
    if (pos.x == self.cursor_pos.x and pos.y == self.cursor_pos.y) return;
    self.cursor_pos = pos;
    self.scrollbar.pointerMoved(pos.x);

    self.core_surface.cursorPosCallback(pos, mouseMods(wparam)) catch |err| {
        log.err("error in cursor pos callback err={}", .{err});
    };
}

fn mouseWheel(self: *Surface, horizontal: bool, wparam: c.WPARAM) void {
    const delta: i16 = @bitCast(c.hiword(wparam));
    const amount = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;

    // Wheels that report less than a full notch are high-resolution.
    const scroll_mods: input.ScrollMods = .{
        .precision = @rem(delta, c.WHEEL_DELTA) != 0,
    };

    // Positive horizontal deltas scroll right on Windows, which is the
    // opposite of the core's convention.
    self.core_surface.scrollCallback(
        if (horizontal) -amount else 0,
        if (horizontal) 0 else amount,
        scroll_mods,
    ) catch |err| {
        log.err("error in scroll callback err={}", .{err});
    };
    if (!horizontal) self.scrollbar.userScrolled();
}

fn imeComposition(self: *Surface, lparam: c.LPARAM) void {
    const bits: usize = @bitCast(lparam);
    if ((bits & c.GCS_COMPSTR) == 0) return;

    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    const size = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
    if (size <= 0) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }

    var wbuf: [256]u16 = undefined;
    const bytes: usize = @min(@as(usize, @intCast(size)), wbuf.len * 2);
    _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, &wbuf, @intCast(bytes));

    var buf: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&buf, wbuf[0 .. bytes / 2]) catch return;
    self.core_surface.preeditCallback(buf[0..len]) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

fn imeStartComposition(self: *Surface) void {
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    // imePoint is in unscaled points at the bottom-middle of the cursor
    // cell; the IME wants client pixels, anchored at the cell's top.
    const pos = self.core_surface.imePoint();
    const sx: f64 = self.content_scale.x;
    const sy: f64 = self.content_scale.y;
    const pt: c.POINT = .{
        .x = @intFromFloat(pos.x * sx),
        .y = @intFromFloat((pos.y - pos.height) * sy),
    };
    _ = c.ImmSetCompositionWindow(himc, &.{
        .dwStyle = c.CFS_POINT,
        .ptCurrentPos = pt,
        .rcArea = std.mem.zeroes(c.RECT),
    });
    _ = c.ImmSetCandidateWindow(himc, &.{
        .dwIndex = 0,
        .dwStyle = c.CFS_EXCLUDE,
        .ptCurrentPos = pt,
        .rcArea = .{
            .left = pt.x,
            .top = pt.y,
            .right = pt.x + @as(c.LONG, @intFromFloat(pos.width * sx)),
            .bottom = pt.y + @as(c.LONG, @intFromFloat(pos.height * sy)),
        },
    });
}

pub fn wndProc(
    hwnd_: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd_, c.GWLP_USERDATA));
    const self: *Surface = if (ptr != 0) @ptrFromInt(ptr) else return c.DefWindowProcW(hwnd_, msg, wparam, lparam);

    switch (msg) {
        c.WM_TIMER => {
            if (wparam == Scrollbar.hide_timer_id) self.scrollbar.onTimer();
            return 0;
        },

        c.WM_SIZE => {
            self.updateSize(c.loword(lparam), c.hiword(lparam));
            return 0;
        },

        // The renderer draws the whole surface; just validate and let
        // it know it needs a fresh frame.
        c.WM_PAINT => {
            _ = c.ValidateRect(hwnd_, null);
            self.core_surface.refreshCallback() catch |err| {
                log.err("error in refresh callback err={}", .{err});
            };
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            const focused = msg == c.WM_SETFOCUS;
            if (focused) self.window.surfaceFocused(self);
            self.core_surface.focusCallback(focused) catch |err| {
                log.err("error in focus callback err={}", .{err});
            };
            return 0;
        },

        c.WM_KEYDOWN, c.WM_KEYUP => {
            _ = self.keyEvent(msg, wparam, lparam);
            return 0;
        },

        c.WM_SYSKEYDOWN => {
            // Unconsumed system keys (e.g. Alt+F4) get default handling.
            if (self.keyEvent(msg, wparam, lparam)) return 0;
            return c.DefWindowProcW(hwnd_, msg, wparam, lparam);
        },

        // Never pass Alt/F10 release to DefWindowProc: it would activate
        // the (non-existent) menu bar and swallow the next key.
        c.WM_SYSKEYUP => {
            _ = self.keyEvent(msg, wparam, lparam);
            return 0;
        },

        c.WM_CHAR => {
            self.charEvent(@truncate(wparam));
            return 0;
        },

        // Stray system chars would beep.
        c.WM_SYSCHAR, c.WM_DEADCHAR, c.WM_SYSDEADCHAR => return 0,

        c.WM_IME_STARTCOMPOSITION => {
            self.imeStartComposition();
            return c.DefWindowProcW(hwnd_, msg, wparam, lparam);
        },

        c.WM_IME_COMPOSITION => {
            self.imeComposition(lparam);
            return c.DefWindowProcW(hwnd_, msg, wparam, lparam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            self.core_surface.preeditCallback(null) catch {};
            return c.DefWindowProcW(hwnd_, msg, wparam, lparam);
        },

        c.WM_LBUTTONDOWN => self.mouseButton(.press, .left, wparam),
        c.WM_LBUTTONUP => self.mouseButton(.release, .left, wparam),
        c.WM_RBUTTONDOWN => self.mouseButton(.press, .right, wparam),
        c.WM_RBUTTONUP => self.mouseButton(.release, .right, wparam),
        c.WM_MBUTTONDOWN => self.mouseButton(.press, .middle, wparam),
        c.WM_MBUTTONUP => self.mouseButton(.release, .middle, wparam),
        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            const button: input.MouseButton = if (c.hiword(wparam) == c.XBUTTON1) .four else .five;
            self.mouseButton(if (msg == c.WM_XBUTTONDOWN) .press else .release, button, wparam);
            return 1;
        },

        c.WM_MOUSEMOVE => self.mouseMove(wparam, lparam),

        c.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.cursor_pos = .{ .x = -1, .y = -1 };
            self.core_surface.cursorPosCallback(self.cursor_pos, key.mods()) catch |err| {
                log.err("error in cursor pos callback err={}", .{err});
            };
        },

        c.WM_MOUSEWHEEL => self.mouseWheel(false, wparam),
        c.WM_MOUSEHWHEEL => self.mouseWheel(true, wparam),

        c.WM_SETCURSOR => if (c.loword(lparam) == c.HTCLIENT) {
            _ = c.SetCursor(if (self.cursor_visible) self.cursor else null);
            return 1;
        },

        else => return c.DefWindowProcW(hwnd_, msg, wparam, lparam),
    }

    return 0;
}

// Clipboard -----------------------------------------------------------------

/// Read the clipboard's text as UTF-8 with CRLF normalized to LF.
/// Returns null if there is no text on the clipboard.
fn readClipboardText(alloc: Allocator, owner: c.HWND) !?[:0]u8 {
    if (c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) == 0) return null;
    if (c.OpenClipboard(owner) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr = c.GlobalLock(handle) orelse return null;
    defer _ = c.GlobalUnlock(handle);

    const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(wide));
    defer alloc.free(utf8);

    var result: std.ArrayList(u8) = try .initCapacity(alloc, utf8.len + 1);
    errdefer result.deinit(alloc);
    for (utf8, 0..) |ch, i| {
        if (ch == '\r' and i + 1 < utf8.len and utf8[i + 1] == '\n') continue;
        result.appendAssumeCapacity(ch);
    }
    return try result.toOwnedSliceSentinel(alloc, 0);
}

/// Write UTF-8 text to the clipboard, converting LF to CRLF.
fn writeClipboardText(alloc: Allocator, owner: c.HWND, text: []const u8) !void {
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(alloc);
    for (text, 0..) |ch, i| {
        if (ch == '\n' and (i == 0 or text[i - 1] != '\r')) try crlf.append(alloc, '\r');
        try crlf.append(alloc, ch);
    }

    const wide = try c.utf16(alloc, crlf.items);
    defer alloc.free(wide);

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
    {
        const dst = c.GlobalLock(mem) orelse {
            _ = c.GlobalFree(mem);
            return error.OutOfMemory;
        };
        defer _ = c.GlobalUnlock(mem);
        const dst_bytes: [*]u8 = @ptrCast(dst);
        @memcpy(dst_bytes[0..bytes], std.mem.sliceAsBytes(wide[0 .. wide.len + 1]));
    }

    if (c.OpenClipboard(owner) == 0) {
        _ = c.GlobalFree(mem);
        return error.ClipboardUnavailable;
    }
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();

    // On success the system owns the memory.
    if (c.SetClipboardData(c.CF_UNICODETEXT, mem) == null) {
        _ = c.GlobalFree(mem);
        return error.ClipboardWriteFailed;
    }
}
