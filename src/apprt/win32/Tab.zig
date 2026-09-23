/// A tab within a window. Each tab owns a split tree of surfaces; all of
/// the surfaces are child windows of the tab's top-level window.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const c = @import("c.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_tab);

pub const Tree = SplitTree(Surface);

window: *Window,

/// The tree of surfaces. Never empty while the tab is alive.
tree: Tree,

/// The surface that most recently had focus in this tab. This is
/// always a view in `tree`.
focused: *Surface,

/// The visible surfaces and their areas from the last layout.
rects: std.ArrayList(SurfaceRect) = .empty,

/// A divider between two split children, computed on layout.
pub const Divider = struct {
    /// The area of the divider itself, in window client coordinates.
    rect: c.RECT,
    /// The split node this divider belongs to.
    handle: Tree.Node.Handle,
    layout: Tree.Split.Layout,
    /// The full area occupied by the split node, used to convert
    /// mouse positions into ratios.
    bounds: c.RECT,
};

pub fn create(
    window: *Window,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Tab {
    const alloc = window.app.core_app.alloc;
    const self = try alloc.create(Tab);
    errdefer alloc.destroy(self);

    const surface = try Surface.create(window.app, window, parent, context);
    // The tree takes its own reference; release the creation reference
    // once we're done (on success or failure).
    defer surface.unref();

    self.* = .{
        .window = window,
        .tree = try .init(alloc, surface),
        .focused = surface,
    };
    return self;
}

/// Destroy the tab and every surface in it.
pub fn destroy(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    self.tree.deinit();
    self.rects.deinit(alloc);
    alloc.destroy(self);
}

/// Replace our tree with a new one, releasing the old.
fn setTree(self: *Tab, tree: Tree) void {
    var old = self.tree;
    self.tree = tree;
    old.deinit();
}

/// Returns true if the given surface is in this tab.
pub fn contains(self: *const Tab, surface: *const Surface) bool {
    return self.tree.locate(surface) != null;
}

/// Returns true if any surface in this tab needs close confirmation.
pub fn needsConfirmQuit(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// Split the given surface in the given direction, returning the new
/// surface. The new surface is focused.
pub fn split(
    self: *Tab,
    from: *Surface,
    direction: apprt.action.SplitDirection,
) !*Surface {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.tree.locate(from) orelse return error.SurfaceNotInTab;

    const surface = try Surface.create(
        self.window.app,
        self.window,
        &from.core_surface,
        .split,
    );
    defer surface.unref();

    var single: Tree = try .init(alloc, surface);
    defer single.deinit();

    self.setTree(try self.tree.split(
        alloc,
        handle,
        switch (direction) {
            .right => .right,
            .down => .down,
            .left => .left,
            .up => .up,
        },
        0.5,
        &single,
    ));

    self.focused = surface;
    return surface;
}

/// Remove a surface from this tab. Returns true if the tab is now empty
/// and should be closed.
pub fn remove(self: *Tab, surface: *Surface) !bool {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.tree.locate(surface) orelse return false;

    // Pick our next focus before removing, preferring the previous split.
    if (self.focused == surface) {
        if (try self.tree.goto(alloc, handle, .previous_wrapped)) |next| {
            if (next != handle) self.focused = self.tree.nodes[next.idx()].leaf;
        }
    }

    // Unzoom if we're removing the zoomed surface.
    if (self.tree.zoomed) |z| if (z == handle) self.tree.zoom(null);

    const tree = try self.tree.remove(alloc, handle);
    if (tree.isEmpty()) {
        // Keep our (now removed) surface out of focus bookkeeping.
        var old = self.tree;
        self.tree = tree;
        old.deinit();
        return true;
    }

    self.setTree(tree);
    return false;
}

/// Move focus to another split. Returns the newly focused surface.
pub fn gotoSplit(self: *Tab, to: apprt.action.GotoSplit) !?*Surface {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.tree.locate(self.focused) orelse return null;
    const next = try self.tree.goto(alloc, handle, switch (to) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    }) orelse return null;
    if (next == handle) return null;

    // Navigating splits exits zoom so the target is visible.
    self.tree.zoom(null);

    const surface = self.tree.nodes[next.idx()].leaf;
    self.focused = surface;
    return surface;
}

/// Resize the split nearest to the focused surface. `size` is the
/// size of the tab's content area in pixels.
pub fn resizeSplit(
    self: *Tab,
    value: apprt.action.ResizeSplit,
    width: u32,
    height: u32,
) !bool {
    if (value.amount == 0 or width == 0 or height == 0) return false;
    if (!self.tree.isSplit()) return false;
    const handle = self.tree.locate(self.focused) orelse return false;

    const amount: f64 = @floatFromInt(value.amount);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const ratio: f64 = switch (value.direction) {
        .right => amount / w,
        .left => -(amount / w),
        .down => amount / h,
        .up => -(amount / h),
    };
    const split_layout: Tree.Split.Layout = switch (value.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const alloc = self.window.app.core_app.alloc;
    self.setTree(try self.tree.resize(
        alloc,
        handle,
        split_layout,
        @floatCast(std.math.clamp(ratio, -1, 1)),
    ));
    return true;
}

pub fn equalize(self: *Tab) !bool {
    if (!self.tree.isSplit()) return false;
    const alloc = self.window.app.core_app.alloc;
    self.setTree(try self.tree.equalize(alloc));
    return true;
}

pub fn toggleZoom(self: *Tab) bool {
    if (!self.tree.isSplit()) return false;
    if (self.tree.zoomed != null) {
        self.tree.zoom(null);
    } else {
        self.tree.zoom(self.tree.locate(self.focused));
    }
    return true;
}

/// Set a split's ratio directly, e.g. while dragging a divider.
pub fn setRatio(self: *Tab, handle: Tree.Node.Handle, ratio: f16) void {
    self.tree.resizeInPlace(handle, std.math.clamp(ratio, 0.05, 0.95));
}

/// Hide every surface in this tab (the tab is no longer selected).
pub fn hide(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| entry.view.setVisible(false);
}

/// Position all surfaces within `rect` and record the dividers
/// between them. Surfaces not shown (due to zoom) are hidden.
pub fn layout(
    self: *Tab,
    rect: c.RECT,
    divider: c.LONG,
    dividers: *std.ArrayList(Divider),
    alloc: Allocator,
) void {
    self.rects.clearRetainingCapacity();
    if (self.tree.zoomed) |zoomed| {
        var it = self.tree.iterator();
        while (it.next()) |entry| entry.view.setVisible(false);
        self.layoutNode(zoomed, rect, divider, dividers, alloc);
    } else {
        self.layoutNode(.root, rect, divider, dividers, alloc);
    }
    self.updateDimming();
}

/// Dim every visible surface except the focused one. Only applies when
/// more than one split is visible.
pub fn updateDimming(self: *Tab) void {
    const dim = self.rects.items.len > 1;
    for (self.rects.items) |r| {
        r.surface.setDimmed(dim and r.surface != self.focused, r.rect);
    }
}

pub const SurfaceRect = struct { surface: *Surface, rect: c.RECT };

fn layoutNode(
    self: *Tab,
    handle: Tree.Node.Handle,
    rect: c.RECT,
    divider: c.LONG,
    dividers: *std.ArrayList(Divider),
    alloc: Allocator,
) void {
    switch (self.tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            surface.setVisible(true);
            self.rects.append(alloc, .{ .surface = surface, .rect = rect }) catch |err| {
                log.warn("error recording surface rect err={}", .{err});
            };
            _ = c.MoveWindow(
                surface.hwnd,
                rect.left,
                rect.top,
                @max(0, rect.right - rect.left),
                @max(0, rect.bottom - rect.top),
                1,
            );
        },

        .split => |s| {
            const ratio: f32 = s.ratio;
            var first = rect;
            var second = rect;
            var div = rect;
            switch (s.layout) {
                .horizontal => {
                    const w = rect.right - rect.left - divider;
                    const at = rect.left + @as(c.LONG, @intFromFloat(@round(@as(f32, @floatFromInt(w)) * ratio)));
                    first.right = at;
                    div.left = at;
                    div.right = at + divider;
                    second.left = at + divider;
                },
                .vertical => {
                    const h = rect.bottom - rect.top - divider;
                    const at = rect.top + @as(c.LONG, @intFromFloat(@round(@as(f32, @floatFromInt(h)) * ratio)));
                    first.bottom = at;
                    div.top = at;
                    div.bottom = at + divider;
                    second.top = at + divider;
                },
            }

            dividers.append(alloc, .{
                .rect = div,
                .handle = handle,
                .layout = s.layout,
                .bounds = rect,
            }) catch |err| log.warn("error recording divider err={}", .{err});

            self.layoutNode(s.left, first, divider, dividers, alloc);
            self.layoutNode(s.right, second, divider, dividers, alloc);
        },
    }
}

/// The title to show for this tab.
pub fn title(self: *const Tab) ?[:0]const u8 {
    return self.focused.title;
}
