//! Keyboard translation helpers for Win32 key messages.
const std = @import("std");
const input = @import("../../input.zig");
const c = @import("c.zig");

/// Returns true if the given virtual key is currently held down.
fn down(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

/// Returns true if the given toggle key (e.g. caps lock) is toggled on.
fn toggled(vk: c_int) bool {
    return (c.GetKeyState(vk) & 1) != 0;
}

/// The current modifier state, as of the message being processed.
pub fn mods() input.Mods {
    var result: input.Mods = .{
        .shift = down(c.VK_SHIFT),
        .ctrl = down(c.VK_CONTROL),
        .alt = down(c.VK_MENU),
        .super = down(c.VK_LWIN) or down(c.VK_RWIN),
        .caps_lock = toggled(c.VK_CAPITAL),
        .num_lock = toggled(c.VK_NUMLOCK),
    };

    if (down(c.VK_RSHIFT) and !down(c.VK_LSHIFT)) result.sides.shift = .right;
    if (down(c.VK_RCONTROL) and !down(c.VK_LCONTROL)) result.sides.ctrl = .right;
    if (down(c.VK_RMENU) and !down(c.VK_LMENU)) result.sides.alt = .right;
    if (down(c.VK_RWIN) and !down(c.VK_LWIN)) result.sides.super = .right;

    return result;
}

/// Returns true if AltGr is held. Windows reports AltGr as a (synthetic)
/// left control plus right alt.
pub fn altGr() bool {
    return down(c.VK_RMENU) and down(c.VK_LCONTROL);
}

/// The native keycode for a key message: the scancode with 0xE000 set
/// for extended keys. This matches the Windows column in keycodes.zig.
pub fn nativeKeycode(vk: u32, lparam: c.LPARAM) u32 {
    const bits: usize = @bitCast(lparam);
    const scancode: u32 = @intCast((bits >> 16) & 0xFF);
    if (scancode == 0) {
        // Synthesized input (SendInput with virtual keys, some remote
        // desktop and on-screen keyboards) may not carry a scancode, so
        // derive it from the virtual key. The result already includes
        // the 0xE0 prefix for extended keys.
        return c.MapVirtualKeyW(vk, c.MAPVK_VK_TO_VSC_EX);
    }
    const extended = (bits & (1 << 24)) != 0;
    return if (extended) 0xE000 | scancode else scancode;
}

/// The physical key for a native keycode.
pub fn physicalKey(native: u32) input.Key {
    if (native == 0) return .unidentified;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

/// The codepoint the key produces with no modifiers applied, using the
/// current keyboard layout. Returns 0 if the key produces no text.
pub fn unshiftedCodepoint(vk: u32, native: u32) u21 {
    const empty: [256]u8 = @splat(0);
    var buf: [4]u16 = undefined;
    // Flag 0x4: don't change the keyboard state (so we don't disturb
    // dead key composition in progress). Windows 10 1607+.
    const n = c.ToUnicodeEx(
        vk,
        native & 0xFF,
        &empty,
        &buf,
        buf.len,
        0x4,
        c.GetKeyboardLayout(0),
    );
    if (n < 1) return 0;
    if (std.unicode.utf16IsHighSurrogate(buf[0])) {
        if (n < 2) return 0;
        return std.unicode.utf16DecodeSurrogatePair(buf[0..2]) catch 0;
    }
    return buf[0];
}

/// Accumulates UTF-16 code units from WM_CHAR messages and produces UTF-8.
pub const TextBuffer = struct {
    utf16: [16]u16 = undefined,
    len: usize = 0,

    pub fn append(self: *TextBuffer, unit: u16) void {
        if (self.len >= self.utf16.len) return;
        self.utf16[self.len] = unit;
        self.len += 1;
    }

    /// Convert to UTF-8 in the given buffer, replacing invalid sequences.
    pub fn utf8(self: *const TextBuffer, buf: []u8) []const u8 {
        var i: usize = 0;
        var it = std.unicode.Utf16LeIterator.init(self.utf16[0..self.len]);
        while (true) {
            const cp = it.nextCodepoint() catch std.unicode.replacement_character orelse break;
            const n = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (i + n > buf.len) break;
            _ = std.unicode.utf8Encode(cp, buf[i..][0..n]) catch continue;
            i += n;
        }
        return buf[0..i];
    }
};

test "nativeKeycode" {
    const testing = std.testing;
    // 'A' key: scancode 0x1E, not extended.
    try testing.expectEqual(@as(u32, 0x1E), nativeKeycode('A', 0x001E0001));
    // Right control: scancode 0x1D, extended.
    try testing.expectEqual(@as(u32, 0xE01D), nativeKeycode(c.VK_RCONTROL, 0x011D0001));
}

test "physicalKey" {
    const testing = std.testing;
    try testing.expectEqual(input.Key.key_a, physicalKey(0x1E));
    try testing.expectEqual(input.Key.control_right, physicalKey(0xE01D));
    try testing.expectEqual(input.Key.unidentified, physicalKey(0));
}

test "TextBuffer surrogate pair" {
    const testing = std.testing;
    var tb: TextBuffer = .{};
    // U+1F600 GRINNING FACE
    tb.append(0xD83D);
    tb.append(0xDE00);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\u{1F600}", tb.utf8(&buf));
}
