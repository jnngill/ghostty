//! Thin WGL bindings for creating and managing OpenGL contexts on Windows.
//!
//! Only the functions used by Ghostty are modelled. The window used with
//! these functions must have a class style of `CS_OWNDC` so that its device
//! context remains valid across threads for the lifetime of the window.

const std = @import("std");

const log = std.log.scoped(.opengl_wgl);

pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
const HMODULE = *opaque {};
const PROC = *const fn () callconv(.c) void;

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_TYPE_RGBA = 0;

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;

extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) c_int;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn GetPixelFormat(hdc: HDC) callconv(.winapi) c_int;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) c_int;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) c_int;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) c_int;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?PROC;
extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?PROC;

const CreateContextAttribsARB = *const fn (
    hdc: HDC,
    share: ?HGLRC,
    attribs: [*]const c_int,
) callconv(.winapi) ?HGLRC;
const SwapIntervalEXT = *const fn (interval: c_int) callconv(.winapi) c_int;

pub const Error = error{
    GetDCFailed,
    PixelFormatFailed,
    CreateContextFailed,
    CreateContextAttribsUnsupported,
    MakeCurrentFailed,
    SwapBuffersFailed,
};

/// Wraps `wglGetProcAddress` for GLAD. WGL only returns extension and
/// post-1.1 functions; core 1.1 functions must come from opengl32.dll
/// directly. Some drivers also return small sentinel values instead of
/// null on failure, which we treat as null.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    const zname: [*:0]const u8 = @ptrCast(name);
    if (wglGetProcAddress(zname)) |proc| {
        switch (@intFromPtr(proc)) {
            1, 2, 3, std.math.maxInt(usize) => {},
            else => return proc,
        }
    }
    const module = GetModuleHandleA("opengl32.dll") orelse return null;
    return GetProcAddress(module, zname);
}

/// A WGL context bound to a specific window's device context.
pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,

    /// Create a core profile context of at least the given version for
    /// the given window. The context is NOT current when this returns.
    pub fn create(hwnd: HWND, major: c_int, minor: c_int) Error!Context {
        const hdc = GetDC(hwnd) orelse return error.GetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        // A window's pixel format can only be set once, so only set it
        // if nobody (e.g. a previous renderer for this window) has yet.
        if (GetPixelFormat(hdc) == 0) {
            const pfd: PIXELFORMATDESCRIPTOR = .{
                .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                .iPixelType = PFD_TYPE_RGBA,
                .cColorBits = 32,
                .cAlphaBits = 8,
            };
            const format = ChoosePixelFormat(hdc, &pfd);
            if (format == 0) return error.PixelFormatFailed;
            if (SetPixelFormat(hdc, format, &pfd) == 0) return error.PixelFormatFailed;
        }

        // We need a legacy context to be current in order to load
        // wglCreateContextAttribsARB, which creates the core context.
        const legacy = wglCreateContext(hdc) orelse return error.CreateContextFailed;
        defer _ = wglDeleteContext(legacy);
        if (wglMakeCurrent(hdc, legacy) == 0) return error.MakeCurrentFailed;
        defer _ = wglMakeCurrent(null, null);

        const create_attribs: CreateContextAttribsARB = @ptrCast(
            getProcAddress("wglCreateContextAttribsARB") orelse
                return error.CreateContextAttribsUnsupported,
        );
        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, major,
            WGL_CONTEXT_MINOR_VERSION_ARB, minor,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const hglrc = create_attribs(hdc, null, &attribs) orelse
            return error.CreateContextFailed;

        return .{ .hwnd = hwnd, .hdc = hdc, .hglrc = hglrc };
    }

    pub fn destroy(self: Context) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
    }

    pub fn makeCurrent(self: Context) Error!void {
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) return error.MakeCurrentFailed;
    }

    pub fn releaseCurrent(self: Context) void {
        _ = self;
        _ = wglMakeCurrent(null, null);
    }

    /// Set the swap interval for the current context, if supported.
    pub fn setSwapInterval(self: Context, interval: c_int) void {
        _ = self;
        const f: SwapIntervalEXT = @ptrCast(
            getProcAddress("wglSwapIntervalEXT") orelse {
                log.info("wglSwapIntervalEXT unsupported, vsync unavailable", .{});
                return;
            },
        );
        _ = f(interval);
    }

    pub fn swapBuffers(self: Context) Error!void {
        if (SwapBuffers(self.hdc) == 0) return error.SwapBuffersFailed;
    }
};
