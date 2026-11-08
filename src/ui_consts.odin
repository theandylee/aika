package main

import "core:sys/windows"

// Named constants for the native UI layer. Values are the literals they replaced;
// constants that core:sys/windows already declares are used from there instead.

// --- Timers and pacing (monotonic milliseconds) ---

APP_TIMER_INTERVAL_MS :: 500          // WM_TIMER period; the tracker still samples at 1 Hz
DAY_RELOAD_INTERVAL_MS :: i64(10_000)  // periodic reload of the selected day
DAY_LOAD_RETRY_MS :: i64(1000)         // minimum spacing between load attempts
TASK_SAVE_INTERVAL_MS :: i64(1000)     // running task persists its endpoint at 1 Hz
MS_PER_MINUTE :: i64(60_000)

// --- Window geometry ---

MIN_WINDOW_W :: i32(720)
MIN_WINDOW_H :: i32(480)
INITIAL_CLIENT_W :: i32(1320)
INITIAL_CLIENT_H :: i32(860)

// --- Input thresholds (pixels) ---

EDGE_HIT_PX :: i32(6)   // grab distance for tag edges and zoom-selection handles
CLICK_DRAG_PX :: i32(3) // pointer travel that turns a click into a range drag
WHEEL_ROWS_PER_NOTCH :: 3

// --- Layout pieces shared by drawing and hit-testing ---

TOOLTIP_H :: i32(24)       // single-line tooltip box
TOOLTIP_GAP :: i32(4)      // gap below the tab strip
TOOLTIP_TEXT_DY :: i32(6)  // text baseline offset inside a single-line tooltip
TOOLBAR_BTN_H :: i32(26)

ZOOM_PAD :: i32(4)         // padding above and below the overview bar
ZOOM_BAR_H :: i32(26)      // overview bar and its buttons
ZOOM_H :: ZOOM_PAD + ZOOM_BAR_H + ZOOM_PAD
ZOOM_LANES_GAP :: i32(4)   // gap between the last lane and the zoom block

SPLITTER_GRIP_LEN :: i32(40) // length of the centered grip line on a pane splitter

// --- System cursor / icon ids (MAKEINTRESOURCE values; windows.IDC_* are cstring) ---

IDC_ARROW   :: u64(32512)
IDC_WAIT    :: u64(32514)
IDC_SIZEWE  :: u64(32644)
IDC_SIZENS  :: u64(32645)
IDC_SIZEALL :: u64(32646)
IDC_HAND    :: u64(32649)
IDI_APPLICATION :: u64(32512)

system_cursor :: proc(id: u64) -> windows.HCURSOR {
	return windows.LoadCursorW(nil, transmute(cstring16)(id))
}

// --- Native control styles, messages and notifications not in core:sys/windows ---

SBS_VERT   :: 1
LBS_NOTIFY :: 1
LBN_DBLCLK :: 2
LBN_SELCHANGE :: 1
LBS_MULTIPLESEL :: 8
LB_SETSEL        :: 0x0185
LB_GETSEL        :: 0x0187
LB_SETCARETINDEX :: 0x019E
LB_GETCARETINDEX :: 0x019F

LB_ADDSTRING    :: 0x0180
LB_RESETCONTENT :: 0x0184
LB_SETCURSEL    :: 0x0186
LB_GETCURSEL    :: 0x0188

MCM_GETCURSEL     :: 0x1001
MCM_SETCURSEL     :: 0x1002
MCM_GETMINREQRECT :: 0x1009
MCM_SETCOLOR      :: 0x100A
MCN_SELECT        :: ~u32(745) // -746

DWMWA_USE_IMMERSIVE_DARK_MODE :: 20

// --- Control ids ---

SETTINGS_ID_MINUTES :: 101
SETTINGS_ID_AUTOSTART :: 102
SETTINGS_ID_IMPORT_MANICTIME :: 103
SETTINGS_ID_FOLDER :: 104
SETTINGS_ID_FOLDER_BROWSE :: 105
SETTINGS_ID_FOLDER_DEFAULT :: 106
SETTINGS_ID_OK      :: windows.IDOK
SETTINGS_ID_CANCEL  :: windows.IDCANCEL

TAG_ID_SEARCH :: 101
TAG_ID_LIST   :: 102
TAG_ID_USE    :: 103
TAG_ID_CREATE :: 104
TAG_ID_CANCEL :: 105

// --- More native constants not in core:sys/windows ---

WS_EX_TOOLWINDOW :: 0x80 // floating tool palette (the date popup)
MONITOR_DEFAULTTONEAREST :: 2

ODS_SELECTED :: 1
ODS_FOCUS    :: 0x10

EM_GETSEL     :: 0xB0
EM_SETSEL     :: 0xB1
EM_REPLACESEL :: 0xC2

CHAR_DELETE :: 0x7F // DEL char; WM_CHAR reports Ctrl+Backspace in an EDIT as this
