"""Deterministic pixel snapshots of the aika client area, for behavior-preserving refactors.

    python tools/pixel-snapshot.py capture build/aika.exe OUT_DIR
    python tools/pixel-snapshot.py compare BASE_DIR NEW_DIR

`capture` builds a synthetic database (fixed activities on the PREVIOUS local day, so
no live bar/now-marker is shown), launches the exe on a temp copy of it, and records
every scene for light/dark themes at 1320x860 and 900x600: each tab, each lane, a
list filter, totals tree mode, zoom, hovered controls and tooltips. Raw client pixels
are written as PNG plus manifest.json (SHA-256 of the pixels per image). The status
bar is masked (it shows the wall clock); nothing else depends on the current time,
except that the date shown is "yesterday", so baseline and candidate must be
captured on the same calendar day.

`compare` lists images whose hash differs, with the number of differing pixels,
and exits 1 if anything differs or is missing.

Only an isolated temp DB is used; no running aika instance is touched.
"""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import sys
import tempfile
import time
import zlib
import native_ui as N
from native_ui import windows_for

u = N.u
g = c.WinDLL("gdi32", use_last_error=True)
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.UpdateWindow.argtypes = [w.HWND]
u.GetClientRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.SetWindowPos.argtypes = [w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT]
u.ClientToScreen.argtypes = [w.HWND, c.POINTER(w.POINT)]
u.SetCursorPos.argtypes = [c.c_int, c.c_int]
u.SetForegroundWindow.argtypes = [w.HWND]
u.GetDC.argtypes = [w.HWND]
u.GetDC.restype = w.HDC
u.ReleaseDC.argtypes = [w.HWND, w.HDC]
u.PrintWindow.argtypes = [w.HWND, w.HDC, w.UINT]
u.PrintWindow.restype = w.BOOL
g.CreateCompatibleDC.argtypes = [w.HDC]
g.CreateCompatibleDC.restype = w.HDC
g.CreateCompatibleBitmap.argtypes = [w.HDC, c.c_int, c.c_int]
g.CreateCompatibleBitmap.restype = w.HBITMAP
g.SelectObject.argtypes = [w.HDC, w.HGDIOBJ]
g.SelectObject.restype = w.HGDIOBJ
g.DeleteObject.argtypes = [w.HGDIOBJ]
g.DeleteDC.argtypes = [w.HDC]


class BitmapInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("width", c.c_long), ("height", c.c_long), ("planes", w.WORD),
                ("bits", w.WORD), ("compression", w.DWORD), ("image_size", w.DWORD),
                ("xppm", c.c_long), ("yppm", c.c_long), ("used", w.DWORD), ("important", w.DWORD)]


g.GetDIBits.argtypes = [w.HDC, w.HBITMAP, w.UINT, w.UINT, c.c_void_p, c.POINTER(BitmapInfo), w.UINT]

SIZES = [(1320, 860), (900, 600)]
THEMES = ["light", "dark"]
STATUS_H = 22
NEUTRAL = (600, 45)  # empty toolbar space: nothing hot, no tooltip


def send(hwnd, msg, wp=0, lp=0):
    return N.send_msg(hwnd, msg, wp, lp)


def point(x, y):
    return N.point(x, y)


def click(hwnd, x, y):
    N.click_at(hwnd, x, y)


def set_text(hwnd, text):
    N.set_text(hwnd, text)


def move(hwnd, x, y):
    """Real cursor move + synthetic WM_MOUSEMOVE.

    The app calls TrackMouseEvent(TME_LEAVE); the OS answers with an immediate
    WM_MOUSELEAVE when the *real* cursor is elsewhere, which would clear every
    synthetic hover. So the physical cursor is parked on the same client point.
    """
    pt = w.POINT(x, y)
    u.ClientToScreen(hwnd, c.byref(pt))
    u.SetCursorPos(pt.x, pt.y)
    time.sleep(0.05)
    send(hwnd, 0x0200, 0, point(x, y))


# --- Mirror of compute_layout() for choosing mouse targets (not used for pass/fail) ---

class Geo:
    def __init__(self, w_, h_):
        self.w, self.h = w_, h_
        bottom = h_ - 30 - 22
        self.chart_x, self.chart_w = 8, w_ - 17
        lane_y = 78 + 24
        area = bottom - lane_y - 120 - 22 - 8 - 34
        wanted = min(96, max(44, area // 3))
        maxh = max(44, (bottom - lane_y - 8 - 4 - 34 - 8 - 100) // 3)
        self.lane_h = max(44, min(wanted, maxh))
        self.lane_y = lane_y
        self.lanes_bottom = lane_y + 3 * self.lane_h + 8
        self.zoom_y = self.lanes_bottom + 4
        self.list_top = self.zoom_y + 34 + 8
        sw = max(180, min(320, max(180, self.chart_w - 8 - 300)))
        self.sidebar_x = self.chart_x + self.chart_w - sw
        self.sidebar_w = sw

    def lane_mid(self, lane):
        return self.lane_y + lane * (self.lane_h + 4) + self.lane_h // 2

    def x_at(self, hour):
        return self.chart_x + int(hour / 24.0 * self.chart_w)


# --- Synthetic data ---

def synthetic_rows(day_start):
    """Deterministic (timeline, group name, color, title, start, end) tuples."""
    apps = [("Code", 0xFF4E79A7), ("Firefox", 0), ("Dev/Terminal", 0xFFF28E2B), ("Dev/Debugger", 0),
            ("Explorer", 0xFF59A14F), ("Slack", 0), ("Spotify", 0xFFB07AA1), ("Notepad", 0)]
    titles = ["main.odin - aika - Visual Studio Code", "Inbox (3) - Mozilla Firefox", "powershell",
              "A rather long window title that must be ellipsized at the list column edge, for sure",
              "Downloads", "#general - Slack", "Spotify Premium", "notes.txt - Notepad"]
    rows = []
    t, seed = 7.5, 12345
    while t < 19.0:
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        dur = (3 + seed % 38) / 60.0
        i = (seed >> 8) % len(apps)
        rows.append((3, apps[i][0], apps[i][1], titles[i], t, t + dur))
        t += dur
    rows.append((3, "Code", 0xFF4E79A7, "pinned.odin - tooltip target", 12.0, 12.67))  # replaces overlap below
    rows = [r for r in rows if not (r[4] < 12.67 and r[5] > 12.0 and r[3] != "pinned.odin - tooltip target")]
    rows += [(2, "Active", 0, "Active", 7.5, 12.5), (2, "Away", 0, "Away", 12.5, 13.0),
             (2, "Active", 0, "Active", 13.0, 18.5), (2, "Away", 0, "Away", 18.5, 19.0)]
    rows += [(1, "Planning", 0xFFFFE08A, "Planning", 8.0, 9.5),  # light fill -> dark text
             (1, "Deep work", 0xFF203040, "Deep work", 9.5, 12.0),  # dark fill -> light text
             (1, "Review", 0xFFE15759, "Review", 13.0, 15.0),
             (1, "Unset color", 0, "Unset color", 15.0, 16.0),
             (1, "Tiny", 0xFF59A14F, "Tiny", 16.5, 16.52)]
    return rows


def build_template(exe, db, work):
    day_start = (datetime.now().replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=1))
    day = (day_start - datetime(2000, 1, 1)).days
    process, hwnd = launch(exe, db)
    stop(process, hwnd)
    with closing(sqlite3.connect(db)) as conn:
        groups = {(r[0], r[1]): r[2] for r in conn.execute('SELECT TimelineId, DisplayName, GroupId FROM "Group"')}
        for tl, name, color, title, a, b in synthetic_rows(day_start):
            key = (tl, name)
            if key not in groups:
                groups[key] = conn.execute('INSERT INTO "Group" (TimelineId, DisplayName, Color, Key) VALUES (?,?,?,?)',
                                           (tl, name, color, f"snap-{tl}-{name}")).lastrowid
            start = day_start + timedelta(hours=a)
            end = day_start + timedelta(hours=b)
            conn.execute('INSERT INTO Activity (TimelineId, DisplayName, GroupId, StartLocalDate, EndLocalDate, '
                         'StartLocalTime, EndLocalTime, StartUtcTime, EndUtcTime, StartUtcMs, EndUtcMs) '
                         'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                         (tl, title, groups[key], day, day, start.isoformat(), end.isoformat(),
                          start.isoformat(), end.isoformat(), int(start.timestamp() * 1000), int(end.timestamp() * 1000)))
        conn.commit()


# --- Process control (shared harness; names kept for test-zoom-ui.py) ---

def launch(exe, db):
    return N.launch_app(exe, db)


def stop(process, hwnd):
    N.stop_app(process, hwnd)


def set_client_size(hwnd, cw, ch):
    for _ in range(2):
        outer, client = w.RECT(), w.RECT()
        u.GetWindowRect(hwnd, c.byref(outer))
        u.GetClientRect(hwnd, c.byref(client))
        dw = (outer.right - outer.left) - client.right
        dh = (outer.bottom - outer.top) - client.bottom
        u.SetWindowPos(hwnd, w.HWND(-1), 20, 20, cw + dw, ch + dh, 0)  # TOPMOST so the cursor reaches it
        time.sleep(0.25)
    u.SetForegroundWindow(hwnd)
    u.GetClientRect(hwnd, c.byref(client))
    assert (client.right, client.bottom) == (cw, ch), (client.right, client.bottom)


# --- Capture / image IO ---

def grab(hwnd, cw, ch):
    """Client-area pixels as top-down BGRA bytes via PrintWindow(PW_CLIENTONLY|FULLCONTENT)."""
    u.UpdateWindow(hwnd)
    screen = u.GetDC(None)
    dc = g.CreateCompatibleDC(screen)
    bmp = g.CreateCompatibleBitmap(screen, cw, ch)
    old = g.SelectObject(dc, bmp)
    try:
        assert u.PrintWindow(hwnd, dc, 0x1 | 0x2), "PrintWindow failed"
        info = BitmapInfo(size=c.sizeof(BitmapInfo), width=cw, height=-ch, planes=1, bits=32)
        buf = c.create_string_buffer(cw * ch * 4)
        assert g.GetDIBits(dc, bmp, 0, ch, buf, c.byref(info), 0) == ch
        return bytearray(buf.raw)
    finally:
        g.SelectObject(dc, old)
        g.DeleteObject(bmp)
        g.DeleteDC(dc)
        u.ReleaseDC(None, screen)


def mask_status_bar(pix, cw, ch):
    """The status bar shows the wall clock (seconds): blank it out."""
    start = (ch - STATUS_H) * cw * 4
    pix[start:] = bytes([255, 0, 255, 255]) * ((ch - (ch - STATUS_H)) * cw)


def write_png(path, pix, cw, ch):
    raw = bytearray()
    for y in range(ch):
        raw.append(0)
        row = pix[y * cw * 4:(y + 1) * cw * 4]
        rgb = bytearray(cw * 3)
        rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
        raw += rgb

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", cw, ch, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def read_png(path):
    data = Path(path).read_bytes()
    pos, idat = 8, b""
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            cw, ch = struct.unpack(">II", body[:8])
        elif tag == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = cw * 3 + 1
    return cw, ch, b"".join(raw[y * stride + 1:(y + 1) * stride] for y in range(ch))


class Session:
    def __init__(self, hwnd, out, manifest, tag, cw, ch):
        self.hwnd, self.out, self.manifest, self.tag, self.cw, self.ch = hwnd, out, manifest, tag, cw, ch
        self.geo = Geo(cw, ch)

    def settled(self, target):
        """Move, then wait until three consecutive frames are identical (status bar masked).
        Child controls and hover state settle asynchronously."""
        move(self.hwnd, *target)
        previous, stable = None, 0
        for _ in range(40):
            time.sleep(0.12)
            pix = grab(self.hwnd, self.cw, self.ch)
            mask_status_bar(pix, self.cw, self.ch)
            stable = stable + 1 if pix == previous else 0
            previous = pix
            if stable >= 2:
                return pix
        return None

    def snap(self, name, hover=None):
        target = hover or NEUTRAL
        # A stray WM_MOUSELEAVE can race a scene; accept only two agreeing rounds.
        for attempt in range(6):
            first = self.settled(target)
            second = self.settled(target)
            if first is not None and first == second:
                pix = first
                break
        else:
            print(f"WARNING: {self.tag}__{name} never settled")
            pix = first or second or bytearray(self.cw * self.ch * 4)
        key = f"{self.tag}__{name}"
        write_png(self.out / f"{key}.png", pix, self.cw, self.ch)
        self.manifest[key] = hashlib.sha256(bytes(pix)).hexdigest()


def run_scenes(exe, template, out, manifest, theme, cw, ch):
    with tempfile.TemporaryDirectory(prefix="aika-pixels-", dir=out.parent) as folder:
        db = Path(folder) / "snap.db"
        shutil.copyfile(template, db)
        Path(str(db) + ".theme").write_text(theme)
        process, hwnd = launch(exe, db)
        try:
            set_client_size(hwnd, cw, ch)
            s = Session(hwnd, out, manifest, f"{theme}_{cw}x{ch}", cw, ch)
            geo = s.geo
            click(hwnd, 20, 50)  # previous day: stable synthetic data, no live overlay
            time.sleep(0.3)
            for lane, lane_name in enumerate(["tags", "computer", "apps"]):
                click(hwnd, 30, geo.lane_mid(lane))
                s.snap(f"day_lane_{lane_name}")
            click(hwnd, 30, geo.lane_mid(2))
            # Filter text (EDIT child, lowercase matching).
            edit = windows_for(process.pid, "EDIT", hwnd)[0]
            set_text(edit, "code")
            time.sleep(0.2)
            s.snap("filter_code")
            set_text(edit, "")
            # Totals tree and zoom.
            click(hwnd, geo.sidebar_x + geo.sidebar_w - 17, geo.list_top + 12)
            s.snap("totals_tree")
            s.snap("totals_tree_tooltip", hover=(geo.sidebar_x + geo.sidebar_w - 17, geo.list_top + 12))
            click(hwnd, geo.sidebar_x + geo.sidebar_w - 17, geo.list_top + 12)
            zoom_in = (geo.chart_x + geo.chart_w - 80 - 17, geo.zoom_y + 4 + 13)
            for _ in range(2):
                click(hwnd, *zoom_in)
            s.snap("zoomed")
            click(hwnd, geo.chart_x + geo.chart_w - 40, geo.zoom_y + 4 + 13)  # reset
            # Hover states and tooltips.
            s.snap("hover_bar_tooltip", hover=(geo.x_at(12.3), geo.lane_mid(2)))
            s.snap("hover_tag_tooltip", hover=(geo.x_at(10.5), geo.lane_mid(0)))
            s.snap("hover_computer_tooltip", hover=(geo.x_at(9.0), geo.lane_mid(1)))
            s.snap("hover_today_button", hover=(60, 50))
            s.snap("hover_date_nav", hover=(20, 50))
            s.snap("hover_task_button", hover=(geo.chart_x + 148 + 232 + 20, 50))
            s.snap("hover_tab", hover=(100, 12))
            s.snap("hover_theme_tooltip", hover=(cw - 20, 12))
            s.snap("hover_settings_tooltip", hover=(cw - 56, 12))
            s.snap("hover_list_row", hover=(100, geo.list_top + 22 + 30))
            s.snap("hover_zoom_bar", hover=(geo.chart_x + 200, geo.zoom_y + 17))
            # Tabs.
            for name, x in [("timesheet", 100), ("statistics", 190)]:
                click(hwnd, x, 12)
                s.snap(f"tab_{name}")
                s.snap(f"tab_{name}_hover_theme", hover=(cw - 20, 12))
            click(hwnd, 20, 12)
            s.snap("tab_day_again")
        finally:
            stop(process, hwnd)


def capture(exe, out):
    out = Path(out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
    root.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="aika-pixels-template-", dir=root) as folder:
        template = Path(folder) / "template.db"
        build_template(str(Path(exe).resolve()), template, folder)
        for theme in THEMES:
            for cw, ch in SIZES:
                run_scenes(str(Path(exe).resolve()), template, out, manifest, theme, cw, ch)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    print(f"captured {len(manifest)} images in {out}")


def compare(base, new):
    base, new = Path(base), Path(new)
    a = json.loads((base / "manifest.json").read_text())
    b = json.loads((new / "manifest.json").read_text())
    bad = 0
    for key in sorted(set(a) | set(b)):
        if key not in a or key not in b:
            print(f"MISSING {key} (in {'base' if key in a else 'new'} only)")
            bad += 1
        elif a[key] != b[key]:
            wa, ha, pa = read_png(base / f"{key}.png")
            wb, hb, pb = read_png(new / f"{key}.png")
            if (wa, ha) != (wb, hb):
                print(f"DIFF {key}: size {wa}x{ha} vs {wb}x{hb}")
            else:
                diff = sum(1 for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3])
                xs = [(i // 3) % wa for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3]]
                ys = [(i // 3) // wa for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3]]
                print(f"DIFF {key}: {diff} pixels differ, bbox x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}")
            bad += 1
    print(f"{len(set(a) | set(b)) - bad} identical, {bad} different/missing")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "capture":
        capture(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)
