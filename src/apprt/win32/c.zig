//! Hand-written Win32 bindings for the win32 apprt.
//!
//! The Zig standard library is removing most of its Win32 surface area
//! (see os/windows.zig), so we declare exactly what we use here. Only the
//! wide-character ("W") variants of APIs are used.

const std = @import("std");

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const ATOM = u16;
pub const LONG = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG_PTR = isize;
pub const HRESULT = c_long;
pub const WCHAR = u16;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HMONITOR = *opaque {};
pub const HANDLE = *anyopaque;
pub const HGLOBAL = *anyopaque;
pub const HKL = *opaque {};
pub const HIMC = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HFONT = *opaque {};
pub const HBITMAP = *opaque {};
pub const HKEY = *opaque {};
pub const COLORREF = DWORD;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?HICON = null,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: LONG,
    lpszName: ?[*:0]const WCHAR,
    lpszClass: ?[*:0]const WCHAR,
    dwExStyle: DWORD,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rcDevice: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = undefined,
    rcWork: RECT = undefined,
    dwFlags: DWORD = 0,
};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const GUID = extern struct {
    data1: u32 = 0,
    data2: u16 = 0,
    data3: u16 = 0,
    data4: [8]u8 = @splat(0),
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]WCHAR = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]WCHAR = @splat(0),
    uVersion: UINT = 0,
    szInfoTitle: [64]WCHAR = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = .{},
    hBalloonIcon: ?HICON = null,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

// Window messages
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_NCCREATE = 0x0081;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_UNICHAR = 0x0109;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

// Window styles
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_CHILD = 0x40000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_POPUP = 0x80000000;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x00200000;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const WS_EX_NOACTIVATE = 0x08000000;
pub const WS_DISABLED = 0x08000000;
pub const LWA_ALPHA = 0x00000002;
pub const SWP_SHOWWINDOW = 0x0040;
pub const SWP_HIDEWINDOW = 0x0080;
pub const HWND_TOP_PTR: ?HWND = null;
pub const CS_HREDRAW = 0x0002;
pub const CS_VREDRAW = 0x0001;
pub const CS_OWNDC = 0x0020;
pub const CS_DBLCLKS = 0x0008;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const GWLP_USERDATA = -21;
pub const GWL_STYLE = -16;
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

// ShowWindow
pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOW = 5;
pub const SW_RESTORE = 9;

// SetWindowPos
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_NOOWNERZORDER = 0x0200;
pub const HWND_TOP: ?HWND = null;

// Size
pub const SIZE_MINIMIZED = 1;

// PeekMessage
pub const PM_REMOVE = 0x0001;

// Mouse
pub const MK_SHIFT = 0x0004;
pub const MK_CONTROL = 0x0008;
pub const XBUTTON1 = 0x0001;
pub const WHEEL_DELTA = 120;
pub const TME_LEAVE = 0x00000002;
pub const HTCLIENT = 1;

// Virtual keys
pub const VK_BACK = 0x08;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;
pub const VK_F10 = 0x79;
pub const VK_NUMLOCK = 0x90;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const MAPVK_VSC_TO_VK_EX = 3;
pub const MAPVK_VK_TO_VSC_EX = 4;

// System commands
pub const SC_KEYMENU = 0xF100;

// Cursors (MAKEINTRESOURCE values)
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;
pub const IDI_APPLICATION: usize = 32512;

// Shell notifications
pub const NIM_ADD = 0x00000000;
pub const NIM_MODIFY = 0x00000001;
pub const NIM_DELETE = 0x00000002;
pub const NIM_SETVERSION = 0x00000004;
pub const NIF_MESSAGE = 0x00000001;
pub const NIF_ICON = 0x00000002;
pub const NIF_TIP = 0x00000004;
pub const NIF_INFO = 0x00000010;
pub const NIF_SHOWTIP = 0x00000080;
pub const NIIF_USER = 0x00000004;
pub const NIIF_LARGE_ICON = 0x00000020;
pub const NOTIFYICON_VERSION_4 = 4;
pub const WM_USER = 0x0400;
pub const NIN_BALLOONUSERCLICK = WM_USER + 5;

// Menus
pub const MF_STRING = 0x00000000;
pub const MF_GRAYED = 0x00000001;
pub const MF_POPUP = 0x00000010;
pub const MF_SEPARATOR = 0x00000800;
pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_NONOTIFY = 0x0080;
pub const TPM_RETURNCMD = 0x0100;

// GDI
pub const TRANSPARENT = 1;
pub const DT_CENTER = 0x00000001;
pub const DT_VCENTER = 0x00000004;
pub const DT_SINGLELINE = 0x00000020;
pub const DT_NOPREFIX = 0x00000800;
pub const DT_END_ELLIPSIS = 0x00008000;
pub const SRCCOPY = 0x00CC0020;
pub const FW_NORMAL = 400;
pub const DEFAULT_CHARSET = 1;
pub const CLEARTYPE_QUALITY = 5;

// Registry
// (HKEY)(ULONG_PTR)(LONG)0x80000001, i.e. sign-extended.
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
pub const RRF_RT_REG_DWORD = 0x00000010;

// Clipboard
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

// MessageBox
pub const MB_OK = 0x00000000;
pub const MB_OKCANCEL = 0x00000001;
pub const MB_YESNO = 0x00000004;
pub const MB_ICONWARNING = 0x00000030;
pub const MB_ICONERROR = 0x00000010;
pub const IDOK = 1;
pub const IDYES = 6;

// MessageBeep
pub const MB_BEEP_DEFAULT = 0xFFFFFFFF;

// Monitor
pub const MONITOR_DEFAULTTONEAREST = 0x00000002;

// DPI
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
pub const USER_DEFAULT_SCREEN_DPI = 96;

// DWM
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;

// IME
pub const GCS_COMPSTR = 0x0008;
pub const GCS_RESULTSTR = 0x0800;
pub const CFS_POINT = 0x0002;
pub const CFS_EXCLUDE = 0x0080;

// user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const WCHAR,
    lpWindowName: [*:0]const WCHAR,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const WCHAR) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(HWND, c_int, c_int, c_int, c_int, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(.winapi) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) i16;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyboardLayout(DWORD) callconv(.winapi) ?HKL;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(.winapi) UINT;
pub extern "user32" fn ToUnicodeEx(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]WCHAR,
    cchBuff: c_int,
    wFlags: UINT,
    dwhkl: ?HKL,
) callconv(.winapi) c_int;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const WCHAR, [*:0]const WCHAR, UINT) callconv(.winapi) c_int;
pub extern "user32" fn MessageBeep(UINT) callconv(.winapi) BOOL;
pub extern "user32" fn FlashWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(HDC, [*]const WCHAR, c_int, *RECT, UINT) callconv(.winapi) c_int;
pub extern "user32" fn PtInRect(*const RECT, POINT) callconv(.winapi) BOOL;

pub extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn AppendMenuW(HMENU, UINT, usize, ?[*:0]const WCHAR) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(HMENU, UINT, c_int, c_int, c_int, HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetParent(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn MapWindowPoints(?HWND, ?HWND, *POINT, UINT) callconv(.winapi) c_int;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetWindowRgn(HWND, ?*anyopaque, BOOL) callconv(.winapi) c_int;

// gdi32
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(HDC, c_int, c_int) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateRoundRectRgn(c_int, c_int, c_int, c_int, c_int, c_int) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: [*:0]const WCHAR,
) callconv(.winapi) ?HFONT;

// advapi32
pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: [*:0]const WCHAR,
    lpValue: [*:0]const WCHAR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) LONG;

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

// kernel32
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const WCHAR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(.winapi) usize;

// shell32
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const WCHAR,
    lpFile: [*:0]const WCHAR,
    lpParameters: ?[*:0]const WCHAR,
    lpDirectory: ?[*:0]const WCHAR,
    nShowCmd: c_int,
) callconv(.winapi) ?HINSTANCE;

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *const NOTIFYICONDATAW) callconv(.winapi) BOOL;

/// Copy UTF-8 into a fixed, null-terminated UTF-16 buffer, truncating.
pub fn copyUtf16(dst: []WCHAR, src: []const u8) void {
    @memset(dst, 0);
    // Text may come from programs in the terminal, so it may not be
    // valid UTF-8; invalid sequences become U+FFFD.
    var i: usize = 0;
    var j: usize = 0;
    while (j < src.len) {
        const len = std.unicode.utf8ByteSequenceLength(src[j]) catch 1;
        const cp: u21 = if (j + len <= src.len)
            std.unicode.utf8Decode(src[j..][0..len]) catch std.unicode.replacement_character
        else
            std.unicode.replacement_character;
        j += @min(len, src.len - j);

        var units: [2]u16 = undefined;
        const n: usize = if (cp >= 0x10000) n: {
            const v = cp - 0x10000;
            units = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) };
            break :n 2;
        } else n: {
            units[0] = @intCast(cp);
            break :n 1;
        };
        if (i + n >= dst.len) break;
        @memcpy(dst[i..][0..n], units[0..n]);
        i += n;
    }
}

// dwmapi
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.winapi) HRESULT;

// imm32
pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(.winapi) LONG;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(.winapi) BOOL;

pub inline fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub inline fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

/// Signed x coordinate from an LPARAM (GET_X_LPARAM).
pub inline fn xParam(lparam: LPARAM) i16 {
    return @bitCast(loword(lparam));
}

/// Signed y coordinate from an LPARAM (GET_Y_LPARAM).
pub inline fn yParam(lparam: LPARAM) i16 {
    return @bitCast(hiword(lparam));
}

/// Convert a UTF-8 string into a null-terminated UTF-16LE string.
pub fn utf16(alloc: std.mem.Allocator, str: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, str);
}

/// Convert a comptime-known ASCII/UTF-8 string literal to UTF-16LE.
pub const L = std.unicode.utf8ToUtf16LeStringLiteral;
