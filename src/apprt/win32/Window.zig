/// A top-level window. A window contains one or more tabs, each of which
/// contains a split tree of surfaces. All surfaces are child windows of
/// this window; only the selected tab's surfaces are visible.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");

const log = std.log.scoped(.win32_window);

pub const class_name = c.L("GhosttyWindow");

/// Deferred close of a surface. wparam: process_active, lparam: *Surface.
const WM_APP_CLOSE_SURFACE = c.WM_APP + 10;

/// Deferred close of tabs. wparam: CloseTabMode, lparam: *Tab.
const WM_APP_CLOSE_TAB = c.WM_APP + 11;

/// Tab bar height and divider thickness in logical (96 DPI) pixels.
const tab_bar_height = 34;
const tab_max_width = 220;
const tab_close_size = 20;
const divider_thickness = 3;

app: *App,
hwnd: c.HWND,

/// All tabs in display order. Never empty while the window is alive
/// (except during construction and destruction).
tabs: std.ArrayList(*Tab) = .empty,

/// The index of the selected tab.
active: usize = 0,

/// Size limits requested by the core, in client-area pixels.
size_limit: ?apprt.action.SizeLimit = null,

/// Saved state when we're in fullscreen, so we can restore it.
fullscreen: ?struct {
    style: c.LONG_PTR,
    placement: c.WINDOWPLACEMENT,
} = null,

/// Dividers of the selected tab, recomputed on every layout.
dividers: std.ArrayList(Tab.Divider) = .empty,

/// The divider being dragged, if any.
drag: ?Tab.Divider = null,

/// The font used for the tab bar, recreated when the DPI changes.
font: ?c.HFONT = null,

/// Set while we're tearing down so that WM_DESTROY doesn't double free.
destroying: bool = false,

pub fn create(app: *App, parent: ?*CoreSurface) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.L("Ghostty"),
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer {
        // Detach first so WM_DESTROY doesn't try to tear us down.
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }

    self.* = .{ .app = app, .hwnd = hwnd };
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    errdefer self.dividers.deinit(alloc);
    errdefer self.tabs.deinit(alloc);

    // Give the window a sensible default size scaled for the monitor.
    // The core may override this via initial_size.
    const content_scale = self.scale();
    self.setClientSize(
        @intFromFloat(@round(800 * content_scale)),
        @intFromFloat(@round(600 * content_scale)),
    );
    self.updateFont();
    self.syncAppearance();

    // Create our first tab. This must happen before the window is shown
    // because the surface's renderer is created synchronously.
    const tab = try Tab.create(self, parent, .window);
    errdefer tab.destroy();
    try self.tabs.append(alloc, tab);
    self.layout();

    const config = &app.config;
    _ = c.ShowWindow(hwnd, if (config.maximize) c.SW_MAXIMIZE else c.SW_SHOWNORMAL);
    if (config.fullscreen != .false) self.toggleFullscreen();

    _ = c.SetFocus(tab.focused.hwnd);
    return self;
}

/// Destroy this window and all of its tabs immediately, without
/// confirmation.
pub fn destroy(self: *Window) void {
    self.teardown(true);
}

fn teardown(self: *Window, destroy_hwnd: bool) void {
    if (self.destroying) return;
    self.destroying = true;
    const alloc = self.app.core_app.alloc;

    // The surfaces must be torn down (stopping the renderer threads that
    // use their DCs) before any HWNDs are destroyed.
    for (self.tabs.items) |tab| tab.destroy();
    self.tabs.deinit(alloc);
    self.dividers.deinit(alloc);
    if (self.font) |f| _ = c.DeleteObject(f);

    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    if (destroy_hwnd) _ = c.DestroyWindow(self.hwnd);

    self.app.removeWindow(self);
    alloc.destroy(self);
}

/// Returns true if closing this window needs confirmation.
pub fn needsConfirmQuit(self: *const Window) bool {
    for (self.tabs.items) |tab| if (tab.needsConfirmQuit()) return true;
    return false;
}

/// Close the window, confirming with the user if needed. This must not
/// be called from within a core surface callback; use `requestClose`.
pub fn close(self: *Window) void {
    if (self.needsConfirmQuit() and !App.confirm(
        self.hwnd,
        "Close window?",
        "A process is still running in this window. " ++
            "Closing it will terminate the process.",
    )) return;

    self.destroy();
}

/// Close the window from the message loop.
pub fn requestClose(self: *Window) void {
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

pub fn activeTab(self: *const Window) *Tab {
    return self.tabs.items[self.active];
}

fn tabIndex(self: *const Window, tab: *const Tab) ?usize {
    for (self.tabs.items, 0..) |t, i| if (t == tab) return i;
    return null;
}

/// Returns the tab containing the given surface, if the surface is
/// still alive in this window.
fn findSurface(self: *const Window, surface: *const Surface) ?*Tab {
    for (self.tabs.items) |tab| if (tab.contains(surface)) return tab;
    return null;
}

// Surfaces ------------------------------------------------------------------

/// Request that a surface be closed. The core calls this from within
/// its own callbacks, so the close happens on the next message loop turn.
pub fn requestCloseSurface(self: *Window, surface: *Surface, process_active: bool) void {
    _ = c.PostMessageW(
        self.hwnd,
        WM_APP_CLOSE_SURFACE,
        @intFromBool(process_active),
        @bitCast(@intFromPtr(surface)),
    );
}

fn handleCloseSurface(self: *Window, surface: *Surface, process_active: bool) void {
    // The surface may have been closed some other way in the meantime.
    const tab = self.findSurface(surface) orelse return;

    if (process_active and surface.core_surface.needsConfirmQuit() and !App.confirm(
        self.hwnd,
        "Close terminal?",
        "A process is still running in this terminal. " ++
            "Closing it will terminate the process.",
    )) return;

    const empty = tab.remove(surface) catch |err| {
        log.err("error removing surface err={}", .{err});
        return;
    };
    if (empty) {
        self.removeTab(tab);
        return;
    }

    self.layout();
    if (tab == self.activeTab()) _ = c.SetFocus(tab.focused.hwnd);
}

/// Called when a surface gains keyboard focus.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const tab = self.findSurface(surface) orelse return;
    tab.focused = surface;
    if (tab == self.activeTab()) {
        self.syncTitle();
        tab.updateDimming();
    }
    self.invalidateTabBar();
}

/// Called when a surface's title changes.
pub fn titleChanged(self: *Window, surface: *Surface) void {
    const tab = self.findSurface(surface) orelse return;
    if (tab.focused != surface) return;
    if (tab == self.activeTab()) self.syncTitle();
    self.invalidateTabBar();
}

fn syncTitle(self: *Window) void {
    const title = self.activeTab().title() orelse "Ghostty";
    var buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const wide = c.utf16(fba.allocator(), title) catch return;
    _ = c.SetWindowTextW(self.hwnd, wide);
}

/// Invoke the given function on every surface in the window.
fn forEachSurface(self: *Window, comptime f: fn (*Surface) void) void {
    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| f(entry.view);
    }
}

// Tabs ----------------------------------------------------------------------

pub fn newTab(self: *Window, parent: ?*CoreSurface) !void {
    const alloc = self.app.core_app.alloc;
    const tab = try Tab.create(self, parent, .tab);
    errdefer tab.destroy();

    const index = switch (self.app.config.@"window-new-tab-position") {
        .current => @min(self.active + 1, self.tabs.items.len),
        .end => self.tabs.items.len,
    };
    try self.tabs.insert(alloc, index, tab);
    self.selectTab(index);
}

pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    if (index != self.active and self.active < self.tabs.items.len) {
        self.tabs.items[self.active].hide();
    }
    self.active = index;
    self.layout();
    self.syncTitle();
    _ = c.SetFocus(self.activeTab().focused.hwnd);
}

pub fn gotoTab(self: *Window, value: apprt.action.GotoTab) bool {
    const n = self.tabs.items.len;
    if (n <= 1) return false;
    const index: usize = switch (value) {
        .previous => if (self.active == 0) n - 1 else self.active - 1,
        .next => if (self.active + 1 >= n) 0 else self.active + 1,
        .last => n - 1,
        _ => idx: {
            const i = @intFromEnum(value);
            if (i < 0) return false;
            break :idx @min(@as(usize, @intCast(i)), n - 1);
        },
    };
    if (index == self.active) return false;
    self.selectTab(index);
    return true;
}

pub fn moveTab(self: *Window, amount: isize) bool {
    const n: isize = @intCast(self.tabs.items.len);
    if (n <= 1 or amount == 0) return false;
    const from: isize = @intCast(self.active);
    const to: usize = @intCast(@mod(from + amount, n));
    const tab = self.tabs.orderedRemove(self.active);
    self.tabs.insertAssumeCapacity(to, tab);
    self.active = to;
    self.invalidateTabBar();
    return true;
}

/// Request that tabs be closed relative to the tab containing `surface`.
pub fn requestCloseTab(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const tab = self.findSurface(surface) orelse return;
    _ = c.PostMessageW(
        self.hwnd,
        WM_APP_CLOSE_TAB,
        @intCast(@intFromEnum(mode)),
        @bitCast(@intFromPtr(tab)),
    );
}

fn handleCloseTab(self: *Window, tab: *Tab, mode: apprt.action.CloseTabMode) void {
    const index = self.tabIndex(tab) orelse return;

    // Collect the tabs to close, then confirm once for all of them.
    var buf: [256]*Tab = undefined;
    var targets: std.ArrayList(*Tab) = .initBuffer(&buf);
    for (self.tabs.items, 0..) |t, i| {
        const include = switch (mode) {
            .this => i == index,
            .other => i != index,
            .right => i > index,
        };
        if (include) targets.appendBounded(t) catch break;
    }
    if (targets.items.len == 0) return;

    const confirm = for (targets.items) |t| {
        if (t.needsConfirmQuit()) break true;
    } else false;
    if (confirm and !App.confirm(
        self.hwnd,
        "Close tab?",
        "A process is still running in this tab. " ++
            "Closing it will terminate the process.",
    )) return;

    for (targets.items) |t| {
        // Removing the last tab destroys the window.
        if (self.tabs.items.len == 1) {
            self.destroy();
            return;
        }
        self.removeTab(t);
    }
}

/// Remove and destroy a tab. Destroys the window if it was the last tab.
fn removeTab(self: *Window, tab: *Tab) void {
    const index = self.tabIndex(tab) orelse return;
    if (self.tabs.items.len == 1) {
        self.destroy();
        return;
    }

    _ = self.tabs.orderedRemove(index);
    tab.destroy();

    if (self.active > index or self.active >= self.tabs.items.len) {
        self.active -|= 1;
    }
    self.selectTab(self.active);
}

// Splits --------------------------------------------------------------------

pub fn newSplit(self: *Window, from: *Surface, direction: apprt.action.SplitDirection) !void {
    const tab = self.findSurface(from) orelse return;
    const surface = try tab.split(from, direction);
    self.layout();
    _ = c.SetFocus(surface.hwnd);
}

pub fn gotoSplit(self: *Window, from: *Surface, to: apprt.action.GotoSplit) !bool {
    const tab = self.findSurface(from) orelse return false;
    tab.focused = from;
    const surface = try tab.gotoSplit(to) orelse return false;
    self.layout();
    _ = c.SetFocus(surface.hwnd);
    return true;
}

pub fn resizeSplit(self: *Window, from: *Surface, value: apprt.action.ResizeSplit) !bool {
    const tab = self.findSurface(from) orelse return false;
    tab.focused = from;
    const rect = self.contentRect();
    const resized = try tab.resizeSplit(
        value,
        @intCast(@max(0, rect.right - rect.left)),
        @intCast(@max(0, rect.bottom - rect.top)),
    );
    if (resized) self.layout();
    return resized;
}

pub fn equalizeSplits(self: *Window, from: *Surface) !bool {
    const tab = self.findSurface(from) orelse return false;
    const equalized = try tab.equalize();
    if (equalized) self.layout();
    return equalized;
}

pub fn toggleSplitZoom(self: *Window, from: *Surface) bool {
    const tab = self.findSurface(from) orelse return false;
    tab.focused = from;
    if (!tab.toggleZoom()) return false;
    self.layout();
    _ = c.SetFocus(tab.focused.hwnd);
    return true;
}

// Layout --------------------------------------------------------------------

fn logical(self: *const Window, v: f32) c.LONG {
    return @intFromFloat(@round(v * self.scale()));
}

fn tabBarVisible(self: *const Window) bool {
    if (self.fullscreen != null) return false;
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
}

fn clientRect(self: *const Window) c.RECT {
    var rect: c.RECT = std.mem.zeroes(c.RECT);
    _ = c.GetClientRect(self.hwnd, &rect);
    return rect;
}

fn tabBarRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.bottom = if (self.tabBarVisible()) rect.top + self.logical(tab_bar_height) else rect.top;
    return rect;
}

/// The area available to the selected tab's surfaces.
fn contentRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.top = self.tabBarRect().bottom;
    return rect;
}

/// Position all surfaces and repaint the window chrome.
pub fn layout(self: *Window) void {
    if (self.tabs.items.len == 0) return;
    const alloc = self.app.core_app.alloc;

    for (self.tabs.items, 0..) |tab, i| {
        if (i != self.active) tab.hide();
    }

    self.dividers.clearRetainingCapacity();
    self.activeTab().layout(
        self.contentRect(),
        @max(1, self.logical(divider_thickness)),
        &self.dividers,
        alloc,
    );

    _ = c.InvalidateRect(self.hwnd, null, 0);
}

fn invalidateTabBar(self: *Window) void {
    if (!self.tabBarVisible()) return;
    const rect = self.tabBarRect();
    _ = c.InvalidateRect(self.hwnd, &rect, 0);
}

// Tab bar -------------------------------------------------------------------

const TabBarHit = union(enum) {
    tab: usize,
    close: usize,
    new_tab,
    empty,
};

fn tabWidth(self: *const Window) c.LONG {
    const bar = self.tabBarRect();
    const n: c.LONG = @intCast(@max(1, self.tabs.items.len));
    const avail = bar.right - bar.left - self.logical(tab_bar_height);
    return @max(self.logical(48), @min(self.logical(tab_max_width), @divTrunc(avail, n)));
}

fn tabRect(self: *const Window, i: usize) c.RECT {
    const bar = self.tabBarRect();
    const w = self.tabWidth();
    const left = bar.left + w * @as(c.LONG, @intCast(i));
    return .{ .left = left, .top = bar.top, .right = left + w, .bottom = bar.bottom };
}

fn tabCloseRect(self: *const Window, i: usize) c.RECT {
    const r = self.tabRect(i);
    const size = self.logical(tab_close_size);
    const pad = @divTrunc(r.bottom - r.top - size, 2);
    return .{
        .left = r.right - pad - size,
        .top = r.top + pad,
        .right = r.right - pad,
        .bottom = r.top + pad + size,
    };
}

fn newTabRect(self: *const Window) c.RECT {
    const bar = self.tabBarRect();
    const left = self.tabRect(self.tabs.items.len).left;
    return .{
        .left = left,
        .top = bar.top,
        .right = left + (bar.bottom - bar.top),
        .bottom = bar.bottom,
    };
}

fn hitTabBar(self: *const Window, pt: c.POINT) ?TabBarHit {
    if (c.PtInRect(&self.tabBarRect(), pt) == 0) return null;
    for (0..self.tabs.items.len) |i| {
        if (c.PtInRect(&self.tabCloseRect(i), pt) != 0) return .{ .close = i };
        if (c.PtInRect(&self.tabRect(i), pt) != 0) return .{ .tab = i };
    }
    if (c.PtInRect(&self.newTabRect(), pt) != 0) return .new_tab;
    return .empty;
}

fn hitDivider(self: *const Window, pt: c.POINT) ?Tab.Divider {
    // Grow the hit area a bit so thin dividers are easy to grab.
    const slop = self.logical(3);
    for (self.dividers.items) |d| {
        var r = d.rect;
        switch (d.layout) {
            .horizontal => {
                r.left -= slop;
                r.right += slop;
            },
            .vertical => {
                r.top -= slop;
                r.bottom += slop;
            },
        }
        if (c.PtInRect(&r, pt) != 0) return d;
    }
    return null;
}

const Colors = struct {
    bar: c.COLORREF,
    active: c.COLORREF,
    text: c.COLORREF,
    text_dim: c.COLORREF,
    divider: c.COLORREF,
};

fn mix(a: configpkg.Config.Color, b: configpkg.Config.Color, t: f32) c.COLORREF {
    const lerp = struct {
        fn f(x: u8, y: u8, tt: f32) u8 {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);
            return @intFromFloat(@round(xf + (yf - xf) * tt));
        }
    }.f;
    return c.rgb(lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t));
}

fn colors(self: *const Window) Colors {
    const config = &self.app.config;
    const bg = config.background;
    const fg = config.foreground;

    const divider = if (config.@"split-divider-color") |d|
        c.rgb(d.r, d.g, d.b)
    else
        mix(bg, fg, 0.25);

    return .{
        .bar = mix(bg, fg, 0.08),
        .active = c.rgb(bg.r, bg.g, bg.b),
        .text = c.rgb(fg.r, fg.g, fg.b),
        .text_dim = mix(fg, bg, 0.45),
        .divider = divider,
    };
}

fn fillRect(hdc: c.HDC, rect: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

fn drawText(hdc: c.HDC, text: []const u8, rect: c.RECT, color: c.COLORREF, flags: c.UINT) void {
    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    var r = rect;
    _ = c.SetTextColor(hdc, color);
    _ = c.DrawTextW(hdc, &buf, @intCast(len), &r, flags);
}

fn paint(self: *Window, hdc: c.HDC) void {
    const client = self.clientRect();
    const cs = self.colors();

    // Everything not covered by a surface is divider-colored; this is
    // what shows between splits.
    fillRect(hdc, client, cs.divider);
    if (!self.tabBarVisible()) return;

    const bar = self.tabBarRect();
    fillRect(hdc, bar, cs.bar);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    const old_font = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(hdc, f);
    };

    const pad = self.logical(12);
    for (self.tabs.items, 0..) |tab, i| {
        const r = self.tabRect(i);
        const is_active = i == self.active;
        if (is_active) fillRect(hdc, r, cs.active);

        // Separator between inactive tabs.
        if (!is_active and i + 1 != self.active and i + 1 < self.tabs.items.len) {
            fillRect(hdc, .{
                .left = r.right - 1,
                .top = r.top + self.logical(8),
                .right = r.right,
                .bottom = r.bottom - self.logical(8),
            }, cs.divider);
        }

        const close_rect = self.tabCloseRect(i);
        var text_rect = r;
        text_rect.left += pad;
        text_rect.right = close_rect.left - self.logical(4);
        drawText(
            hdc,
            tab.title() orelse "Ghostty",
            text_rect,
            if (is_active) cs.text else cs.text_dim,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );
        drawText(
            hdc,
            "\u{2715}",
            close_rect,
            cs.text_dim,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX,
        );
    }

    drawText(
        hdc,
        "+",
        self.newTabRect(),
        cs.text_dim,
        c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX,
    );
}

fn onPaint(self: *Window) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    // Double buffer to avoid flicker while resizing.
    const client = self.clientRect();
    const w = client.right - client.left;
    const h = client.bottom - client.top;
    if (w <= 0 or h <= 0) return;

    const mem = c.CreateCompatibleDC(hdc) orelse return self.paint(hdc);
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, w, h) orelse return self.paint(hdc);
    defer _ = c.DeleteObject(bmp);
    const old = c.SelectObject(mem, bmp);
    defer if (old) |o| {
        _ = c.SelectObject(mem, o);
    };

    self.paint(mem);
    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn updateFont(self: *Window) void {
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = c.CreateFontW(
        -self.logical(12),
        0,
        0,
        0,
        c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        0,
        0,
        c.CLEARTYPE_QUALITY,
        0,
        c.L("Segoe UI"),
    );
}

fn onMouseDown(self: *Window, button: enum { left, middle }, lparam: c.LPARAM) void {
    const pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };

    if (self.hitTabBar(pt)) |hit| {
        switch (button) {
            .left => switch (hit) {
                .tab => |i| self.selectTab(i),
                .close => |i| self.handleCloseTab(self.tabs.items[i], .this),
                .new_tab => self.newTab(self.activeTab().focused.core()) catch |err| {
                    log.err("error creating tab err={}", .{err});
                },
                .empty => {},
            },
            .middle => switch (hit) {
                .tab, .close => |i| self.handleCloseTab(self.tabs.items[i], .this),
                .new_tab, .empty => {},
            },
        }
        return;
    }

    if (button == .left) {
        if (self.hitDivider(pt)) |d| {
            self.drag = d;
            _ = c.SetCapture(self.hwnd);
        }
    }
}

fn onMouseMove(self: *Window, lparam: c.LPARAM) void {
    const d = self.drag orelse return;
    const x: f32 = @floatFromInt(c.xParam(lparam));
    const y: f32 = @floatFromInt(c.yParam(lparam));
    const b = d.bounds;
    const ratio: f32 = switch (d.layout) {
        .horizontal => (x - @as(f32, @floatFromInt(b.left))) /
            @as(f32, @floatFromInt(@max(1, b.right - b.left))),
        .vertical => (y - @as(f32, @floatFromInt(b.top))) /
            @as(f32, @floatFromInt(@max(1, b.bottom - b.top))),
    };
    self.activeTab().setRatio(d.handle, @floatCast(ratio));
    self.layout();
}

fn onSetCursor(self: *Window) bool {
    var pt: c.POINT = undefined;
    if (c.GetCursorPos(&pt) == 0) return false;
    _ = c.ScreenToClient(self.hwnd, &pt);
    const d = self.drag orelse self.hitDivider(pt) orelse return false;
    _ = c.SetCursor(c.LoadCursorW(null, switch (d.layout) {
        .horizontal => c.IDC_SIZEWE,
        .vertical => c.IDC_SIZENS,
    }));
    return true;
}

// Window management ---------------------------------------------------------

/// The content scale of the window based on its current monitor's DPI.
pub fn scale(self: *const Window) f32 {
    const dpi = c.GetDpiForWindow(self.hwnd);
    if (dpi == 0) return 1;
    return @as(f32, @floatFromInt(dpi)) / c.USER_DEFAULT_SCREEN_DPI;
}

/// Resize the window so its client area is exactly the given size.
fn setClientSize(self: *Window, width: u32, height: u32) void {
    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @intCast(height),
    };
    const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    _ = c.AdjustWindowRectExForDpi(&rect, style, 0, 0, c.GetDpiForWindow(self.hwnd));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// Apply the core's requested initial size. This is only honored while
/// the window still has a single, unsplit terminal.
pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    if (self.fullscreen != null) return;
    if (c.IsZoomed(self.hwnd) != 0) return;
    if (self.tabs.items.len > 1) return;
    if (self.tabs.items.len == 1 and self.tabs.items[0].tree.isSplit()) return;
    const bar: u32 = @intCast(self.tabBarRect().bottom);
    self.setClientSize(width, height + bar);
}

pub fn toggleMaximize(self: *Window) void {
    if (self.fullscreen != null) return;
    _ = c.ShowWindow(
        self.hwnd,
        if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE,
    );
}

/// Toggle a borderless fullscreen window covering the current monitor.
pub fn toggleFullscreen(self: *Window) void {
    if (self.fullscreen) |saved| {
        self.fullscreen = null;
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER |
                c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
        );
        self.layout();
        return;
    }

    var placement: c.WINDOWPLACEMENT = .{};
    if (c.GetWindowPlacement(self.hwnd, &placement) == 0) return;
    const monitor = c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MONITORINFO = .{};
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;

    const style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE);
    self.fullscreen = .{ .style = style, .placement = placement };
    _ = c.SetWindowLongPtrW(
        self.hwnd,
        c.GWL_STYLE,
        style & ~@as(c.LONG_PTR, c.WS_OVERLAPPEDWINDOW),
    );
    _ = c.SetWindowPos(
        self.hwnd,
        c.HWND_TOP,
        info.rcMonitor.left,
        info.rcMonitor.top,
        info.rcMonitor.right - info.rcMonitor.left,
        info.rcMonitor.bottom - info.rcMonitor.top,
        c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
    );
    self.layout();
}

pub fn ringBell(self: *Window) void {
    _ = c.MessageBeep(c.MB_BEEP_DEFAULT);
    if (c.GetForegroundWindow() != self.hwnd) _ = c.FlashWindow(self.hwnd, 1);
}

/// Bring the window to the front with the given surface focused.
pub fn present(self: *Window, surface: ?*Surface) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
    if (surface) |s| {
        if (self.findSurface(s)) |tab| {
            tab.focused = s;
            if (self.tabIndex(tab)) |i| self.selectTab(i);
            return;
        }
    }
    _ = c.SetFocus(self.activeTab().focused.hwnd);
}

/// Whether our chrome (title bar, scrollbars) should be dark.
pub fn isDark(self: *const Window) bool {
    const config = &self.app.config;
    return switch (config.@"window-theme") {
        .light => false,
        .dark => true,
        .system => self.app.color_scheme == .dark,
        .auto, .ghostty => config.background.toTerminalRGB().perceivedLuminance() < 0.5,
    };
}

/// Update window chrome (e.g. a dark title bar) to match the config.
pub fn syncAppearance(self: *Window) void {
    const dark = self.isDark();
    const dark_bool: c.BOOL = @intFromBool(dark);
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        c.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark_bool,
        @sizeOf(c.BOOL),
    );
    for (self.tabs.items) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.syncTheme(dark);
    }
    self.layout();
}

fn updateContentScale(surface: *Surface) void {
    surface.updateContentScale();
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    const self: *Window = if (ptr != 0) @ptrFromInt(ptr) else return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_CLOSE => {
            self.close();
            return 0;
        },

        WM_APP_CLOSE_SURFACE => {
            // Validated by handleCloseSurface before use.
            const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.handleCloseSurface(surface, wparam != 0);
            return 0;
        },

        WM_APP_CLOSE_TAB => {
            // Validated by handleCloseTab before use.
            const tab: *Tab = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const mode = std.enums.fromInt(apprt.action.CloseTabMode, wparam) orelse return 0;
            self.handleCloseTab(tab, mode);
            return 0;
        },

        c.WM_SIZE => {
            self.layout();
            return 0;
        },

        c.WM_PAINT => {
            self.onPaint();
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_LBUTTONDOWN => {
            self.onMouseDown(.left, lparam);
            return 0;
        },

        c.WM_LBUTTONDBLCLK => {
            const pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
            if (self.hitTabBar(pt)) |hit| if (hit == .empty) {
                self.newTab(self.activeTab().focused.core()) catch |err| {
                    log.err("error creating tab err={}", .{err});
                };
            };
            return 0;
        },

        c.WM_MBUTTONDOWN => {
            self.onMouseDown(.middle, lparam);
            return 0;
        },

        c.WM_MOUSEMOVE => {
            self.onMouseMove(lparam);
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.drag != null) {
                self.drag = null;
                _ = c.ReleaseCapture();
            }
            return 0;
        },

        c.WM_SETCURSOR => {
            if (c.loword(lparam) == c.HTCLIENT and self.onSetCursor()) return 1;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_SETFOCUS => {
            if (self.tabs.items.len > 0) _ = c.SetFocus(self.activeTab().focused.hwnd);
            return 0;
        },

        c.WM_ACTIVATE => {
            if (c.loword(wparam) != 0 and self.tabs.items.len > 0) {
                _ = c.SetFocus(self.activeTab().focused.hwnd);
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_ACTIVATEAPP => {
            self.app.core_app.focusEvent(wparam != 0);
            return 0;
        },

        c.WM_SETTINGCHANGE => {
            self.app.settingChanged(lparam);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_DPICHANGED => {
            // Move to the suggested rect, then let the surfaces pick up
            // their new content scale.
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            self.updateFont();
            self.forEachSurface(updateContentScale);
            self.layout();
            return 0;
        },

        c.WM_GETMINMAXINFO => {
            const limit = self.size_limit orelse
                return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            var rect: c.RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(limit.min_width),
                .bottom = @intCast(limit.min_height),
            };
            const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
            _ = c.AdjustWindowRectExForDpi(&rect, style, 0, 0, c.GetDpiForWindow(hwnd));
            info.ptMinTrackSize = .{
                .x = rect.right - rect.left,
                .y = rect.bottom - rect.top,
            };
            return 0;
        },

        c.WM_DESTROY => {
            // If we weren't destroyed via `destroy` (which is the normal
            // path), make sure we clean up. The HWND is already going away.
            self.teardown(false);
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
