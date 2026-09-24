//! An overlay scrollbar for a surface, matching the overlay scrollbars
//! used by the GTK and macOS apps: it takes no space from the terminal,
//! appears while scrolling or when the pointer nears the right edge, and
//! hides again shortly after.
//!
//! Only the thumb is drawn. It is a small translucent child window of
//! the top-level window positioned over the surface's right edge.
const Scrollbar = @This();

const std = @import("std");
const terminal = @import("../../terminal/main.zig");

const c = @import("c.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_scrollbar);

pub const class_name = c.L("GhosttyScrollbar");

/// Timer (on the surface window) used to hide the scrollbar.
pub const hide_timer_id = 2;
const hide_delay_ms = 1000;

/// Sizes in logical (96 DPI) pixels.
const width_idle = 6;
const width_hover = 10;
const margin = 2;
const min_thumb = 24;

/// Distance from the right edge at which pointer motion reveals the
/// scrollbar, in logical pixels.
const reveal_distance = 24;

/// Thumb opacity (0-255).
const alpha = 140;

surface: *Surface,

/// The thumb window, created on first show.
hwnd: ?c.HWND = null,

/// The latest scroll state from the core.
state: terminal.Scrollbar = .zero,

/// The surface's area in the top-level window's client coordinates.
frame: c.RECT = std.mem.zeroes(c.RECT),

visible: bool = false,
hovered: bool = false,

/// Active thumb drag: the pointer's starting screen y and the viewport
/// offset when the drag began.
drag: ?struct { start_y: c.LONG, start_offset: usize } = null,

pub fn deinit(self: *Scrollbar) void {
    if (self.hwnd) |h| _ = c.DestroyWindow(h);
    self.* = undefined;
}

fn enabled(self: *const Scrollbar) bool {
    return self.surface.app.config.scrollbar == .system;
}

/// Whether there is anything to scroll.
fn scrollable(self: *const Scrollbar) bool {
    return self.state.total > self.state.len;
}

/// Whether the viewport is at the bottom of the scrollback.
fn atBottom(self: *const Scrollbar) bool {
    return self.state.offset + self.state.len >= self.state.total;
}

/// Update the scroll state reported by the core.
pub fn setState(self: *Scrollbar, value: terminal.Scrollbar) void {
    const moved = value.offset != self.state.offset;
    self.state = value;

    if (!self.scrollable()) return self.hide();

    // Output arriving while we're at the bottom also moves the offset;
    // don't flash the scrollbar for that, only for scrolling back.
    if (moved and !self.atBottom()) return self.show();
    if (self.visible) self.reposition();
}

/// The user scrolled (e.g. with the mouse wheel).
pub fn userScrolled(self: *Scrollbar) void {
    if (self.scrollable()) self.show();
}

/// The pointer moved within the surface to the given x (client pixels).
pub fn pointerMoved(self: *Scrollbar, x: f32) void {
    if (!self.scrollable()) return;
    const width: f32 = @floatFromInt(self.frame.right - self.frame.left);
    if (x >= width - @as(f32, @floatFromInt(self.logical(reveal_distance)))) self.show();
}

/// The surface was laid out at a new position.
pub fn setFrame(self: *Scrollbar, frame: c.RECT) void {
    self.frame = frame;
    if (self.visible) self.reposition();
}

pub fn hide(self: *Scrollbar) void {
    if (!self.visible) return;
    self.visible = false;
    self.hovered = false;
    if (self.hwnd) |h| _ = c.ShowWindow(h, c.SW_HIDE);
    _ = c.KillTimer(self.surface.hwnd, hide_timer_id);
}

/// Called when the hide timer fires.
pub fn onTimer(self: *Scrollbar) void {
    if (self.drag != null or self.hovered) return;
    self.hide();
}

fn show(self: *Scrollbar) void {
    if (!self.enabled() or !self.surface.visible) return;
    if (self.hwnd == null) self.hwnd = self.createWindow() orelse return;
    self.visible = true;
    self.reposition();
    _ = c.SetTimer(self.surface.hwnd, hide_timer_id, hide_delay_ms, null);
}

fn createWindow(self: *Scrollbar) ?c.HWND {
    const h = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE,
        class_name,
        c.L(""),
        c.WS_CHILD,
        0,
        0,
        0,
        0,
        self.surface.window.hwnd,
        null,
        self.surface.app.hinstance,
        null,
    ) orelse {
        log.warn("failed to create scrollbar window", .{});
        return null;
    };
    _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetLayeredWindowAttributes(h, 0, alpha, c.LWA_ALPHA);
    return h;
}

fn logical(self: *const Scrollbar, v: f32) c.LONG {
    return @intFromFloat(@round(v * self.surface.content_scale.y));
}

/// The track the thumb moves along, in window client coordinates.
fn track(self: *const Scrollbar) c.RECT {
    const m = self.logical(margin);
    return .{
        .left = self.frame.right - m - self.logical(width_hover),
        .top = self.frame.top + m,
        .right = self.frame.right - m,
        .bottom = self.frame.bottom - m,
    };
}

fn thumbRect(self: *const Scrollbar) c.RECT {
    const t = self.track();
    const track_h: f64 = @floatFromInt(@max(1, t.bottom - t.top));
    const total: f64 = @floatFromInt(@max(1, self.state.total));
    const len: f64 = @floatFromInt(self.state.len);
    const offset: f64 = @floatFromInt(self.state.offset);

    const min_h: f64 = @floatFromInt(self.logical(min_thumb));
    const h = @min(track_h, @max(min_h, track_h * len / total));
    const max_offset = @max(1, total - len);
    const y = (track_h - h) * @min(1, offset / max_offset);

    const w = self.logical(if (self.hovered or self.drag != null) width_hover else width_idle);
    const top = t.top + @as(c.LONG, @intFromFloat(@round(y)));
    return .{
        .left = t.right - w,
        .top = top,
        .right = t.right,
        .bottom = top + @as(c.LONG, @intFromFloat(@round(h))),
    };
}

fn reposition(self: *Scrollbar) void {
    const h = self.hwnd orelse return;
    const r = self.thumbRect();
    const w = r.right - r.left;
    const ht = r.bottom - r.top;
    _ = c.SetWindowPos(h, c.HWND_TOP, r.left, r.top, w, ht, c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);

    // A pill-shaped thumb. The window owns the region after this call.
    if (c.CreateRoundRectRgn(0, 0, w + 1, ht + 1, w, w)) |rgn| {
        _ = c.SetWindowRgn(h, rgn, 1);
    }
}

/// Scroll so the thumb follows a drag that has moved `dy` pixels.
fn dragTo(self: *Scrollbar, dy: c.LONG) void {
    const d = self.drag orelse return;
    const t = self.track();
    const thumb = self.thumbRect();
    const free: f64 = @floatFromInt(@max(1, (t.bottom - t.top) - (thumb.bottom - thumb.top)));
    const max_offset: f64 = @floatFromInt(self.state.total -| self.state.len);
    const delta = @as(f64, @floatFromInt(dy)) * max_offset / free;
    const start: f64 = @floatFromInt(d.start_offset);
    const row: usize = @intFromFloat(std.math.clamp(@round(start + delta), 0, max_offset));
    _ = self.surface.core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
        log.err("error performing scroll_to_row action err={}", .{err});
    };
}

fn color(self: *const Scrollbar) c.COLORREF {
    const config = &self.surface.app.config;
    const fg = config.foreground;
    return c.rgb(fg.r, fg.g, fg.b);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Scrollbar = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            const brush = c.CreateSolidBrush(self.color()) orelse return 0;
            defer _ = c.DeleteObject(brush);
            _ = c.FillRect(hdc, &ps.rcPaint, brush);
            return 0;
        },

        c.WM_SETCURSOR => {
            _ = c.SetCursor(c.LoadCursorW(null, c.IDC_ARROW));
            return 1;
        },

        c.WM_LBUTTONDOWN => {
            var pt: c.POINT = undefined;
            if (c.GetCursorPos(&pt) == 0) return 0;
            self.drag = .{ .start_y = pt.y, .start_offset = self.state.offset };
            _ = c.SetCapture(hwnd);
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (!self.hovered) {
                self.hovered = true;
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                _ = c.TrackMouseEvent(&tme);
                self.reposition();
            }
            if (self.drag) |d| {
                var pt: c.POINT = undefined;
                if (c.GetCursorPos(&pt) != 0) self.dragTo(pt.y - d.start_y);
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.hovered = false;
            if (self.visible) self.reposition();
            _ = c.SetTimer(self.surface.hwnd, hide_timer_id, hide_delay_ms, null);
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.drag != null) {
                self.drag = null;
                _ = c.ReleaseCapture();
                if (self.visible) self.reposition();
                _ = c.SetTimer(self.surface.hwnd, hide_timer_id, hide_delay_ms, null);
            }
            return 0;
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
