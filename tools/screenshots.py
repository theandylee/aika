"""Generate README screenshots: light, dark, and a diagonal light/dark split.

    python tools/screenshots.py [--out docs/screenshots] [--size 1320x860] [--no-build] [--exe build/aika.exe]

Steps: rebuild (build.bat, skip with --no-build), seed a throwaway database with a
deterministic fake workday on the previous local day, launch the exe on a copy of it
once per theme (own folder, own aika-settings.toml; update checks off), capture the
window's client area, and compose the split image. Writes into --out:

    aika-light.png   aika-dark.png   aika-split.png

Nothing real is touched: only a temp DB is used, and the previous day is shown so the
live tracker (which records whatever window is in front) never appears in a shot.
The script refuses to run while a normal aika is open: the GUI is single-instance
(a fixed per-session mutex), so a second launch would just focus the running one.
"""
import argparse
import ctypes as c
from contextlib import closing
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import random
import shutil
import sqlite3
import subprocess
import sys
import time
import native_ui as N

here = Path(__file__).resolve().parent
repo = here.parent
spec = importlib.util.spec_from_file_location("pixel_snapshot", here / "pixel-snapshot.py")
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)

SPLIT_SLANT = 0.12  # the split line runs from (cx + slant*h, 0) down to (cx - slant*h, h)
PREV_DAY_BUTTON = (20, 50)
NEUTRAL = (600, 45)  # empty toolbar space: nothing hot, no tooltip

# --- Fake workday ---------------------------------------------------------------

# name -> colour (ARGB int, 0 = automatic)
APPS = {
    "Code": 0, "Windows Terminal": 0, "Firefox": 0, "Slack": 0, "Figma": 0,
    "Zoom": 0, "Outlook": 0, "Explorer": 0, "Spotify": 0,
}
TITLES = {
    "Code": ["tracker.odin - aika - Visual Studio Code", "ui.odin - aika - Visual Studio Code",
             "db.odin - aika - Visual Studio Code", "ROADMAP.md - aika - Visual Studio Code"],
    "Windows Terminal": ["PowerShell", "odin check src -vet", "build.bat"],
    "Firefox": ["Odin Programming Language - Mozilla Firefox", "Pull requests · aika - GitHub - Mozilla Firefox",
                "Win32 API reference - Mozilla Firefox", "Inbox (3) - Mozilla Firefox"],
    "Slack": ["#general - Acme - Slack", "#dev - Acme - Slack"],
    "Figma": ["Dashboard redesign - Figma"],
    "Zoom": ["Zoom Meeting"],
    "Outlook": ["Inbox - Outlook"],
    "Explorer": ["Downloads", "aika"],
    "Spotify": ["Spotify Premium"],
}

def hm(text):
    """'13:45' -> 13.75 (hours since midnight)."""
    h, m = text.split(":")
    return int(h) + int(m) / 60.0


# The day has a clear midday gap (12:15-14:00) in every lane so the split line can pass
# through it without cutting a block: morning blocks end up on the light side, afternoon
# blocks on the dark side. The view is zoomed to VIEW so the blocks fill ~78% of the
# width; the gap is centred in the view (and the split line at the window centre).
# Keep the gap wide enough for the slant (see SPLIT_SLANT).
VIEW = (hm("8:00"), hm("18:15"))

# (start, end, {app: weight}) -- applications lane, switches every 1-14 min
APP_PLAN = [
    (hm("8:15"), hm("8:45"), {"Outlook": 3, "Slack": 3, "Firefox": 2}),
    (hm("8:45"), hm("10:15"), {"Code": 8, "Windows Terminal": 4, "Firefox": 2}),
    (hm("10:15"), hm("10:45"), {"Zoom": 1}),
    (hm("10:45"), hm("12:15"), {"Code": 7, "Windows Terminal": 3, "Firefox": 3, "Spotify": 1}),
    (hm("14:00"), hm("14:45"), {"Slack": 3, "Outlook": 3, "Firefox": 3, "Explorer": 1}),
    (hm("14:45"), hm("16:00"), {"Figma": 6, "Firefox": 2, "Slack": 1}),
    (hm("16:00"), hm("16:30"), {"Zoom": 1}),
    (hm("16:30"), hm("18:00"), {"Code": 8, "Windows Terminal": 4, "Firefox": 2, "Spotify": 1}),
]
# computer usage: Active / Away
USAGE = [("Active", hm("8:15"), hm("12:15")), ("Active", hm("14:00"), hm("18:00")), ("Away", hm("18:00"), hm("18:15"))]
# tags (colour of each name's group)
TAGS = {
    "Admin": 0xFF76B7B2, "Meetings": 0xFFE15759, "Project/aika": 0xFF4E79A7, "Project/website": 0xFFF28E2B,
}
# ([names], start, end); the first name is the block's primary tag
TAG_PLAN = [
    (["Admin"], hm("8:15"), hm("8:45")),
    (["Project/aika"], hm("8:45"), hm("10:15")),
    (["Meetings", "Project/aika"], hm("10:15"), hm("10:45")),
    (["Project/aika"], hm("10:45"), hm("12:15")),
    (["Admin"], hm("14:00"), hm("14:45")),
    (["Project/website"], hm("14:45"), hm("16:00")),
    (["Meetings"], hm("16:00"), hm("16:30")),
    (["Project/aika"], hm("16:30"), hm("18:00")),
]


def app_rows(rng):
    rows = []
    for start, end, weights in APP_PLAN:
        names, w = list(weights), list(weights.values())
        t, last = start, None
        while t < end - 1e-6:
            choices = [n for n in names if n != last] or names
            cw = [weights[n] for n in choices]
            app = rng.choices(choices, cw)[0]
            dur = min(rng.randint(1, 14) / 60.0 if len(names) > 1 else end - t, end - t)
            if end - (t + dur) < 2 / 60.0:
                dur = end - t  # no sliver left at the end of a block
            rows.append((app, rng.choice(TITLES[app]), t, t + dur))
            t, last = t + dur, app
    return rows


def local_text(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def seed(db, day_start):
    """Fill an app-created database with the fake day. `day_start` is local midnight."""
    day = (day_start - datetime(2000, 1, 1)).days  # ManicTime date: days since 2000-01-01
    rng = random.Random(20260101)

    def insert(conn, tl, title, group_id, list_id, a, b):
        s, e = day_start + timedelta(hours=a), day_start + timedelta(hours=b)
        su, eu = (x.astimezone(timezone.utc) for x in (s, e))  # naive local -> aware via astimezone
        conn.execute(
            'INSERT INTO Activity (TimelineId, DisplayName, GroupId, GroupListId, StartLocalDate, EndLocalDate, '
            'StartLocalTime, EndLocalTime, StartUtcTime, EndUtcTime, StartUtcMs, EndUtcMs) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
            (tl, title, group_id, list_id, day, day, local_text(s), local_text(e), local_text(su), local_text(eu),
             int(s.timestamp() * 1000), int(e.timestamp() * 1000)))

    with closing(sqlite3.connect(db)) as conn:
        def group(tl, name, color):
            row = conn.execute('SELECT GroupId FROM "Group" WHERE TimelineId=? AND Key=?', (tl, f"fake-{name}")).fetchone()
            if row:
                return row[0]
            return conn.execute('INSERT INTO "Group" (TimelineId, DisplayName, Color, Key) VALUES (?,?,?,?)',
                                (tl, name, color, f"fake-{name}")).lastrowid

        for name, a, b in USAGE:
            insert(conn, 2, name, group(2, name, 0), None, a, b)
        for app, title, a, b in app_rows(rng):
            insert(conn, 3, title, group(3, app, APPS[app]), None, a, b)
        tag_ids = {n: group(1, n, col) for n, col in TAGS.items()}
        for names, a, b in TAG_PLAN:
            key = ";".join(sorted(names))
            row = conn.execute("SELECT GroupListId FROM GroupList WHERE TimelineId=1 AND Key=?", (key,)).fetchone()
            if row:
                list_id = row[0]
            else:
                list_id = conn.execute("INSERT INTO GroupList (TimelineId, Key) VALUES (1,?)", (key,)).lastrowid
                for order, n in enumerate(names):
                    conn.execute("INSERT INTO GroupListItem (GroupListId, GroupId, DisplayOrder) VALUES (?,?,?)",
                                 (list_id, tag_ids[n], order))
            insert(conn, 1, ", ".join(names), tag_ids[names[0]], list_id, a, b)
        conn.commit()


# --- Capture ----------------------------------------------------------------------

def write_settings(folder, theme):
    # Updates off: a screenshot run must not touch the network.
    (folder / "aika-settings.toml").write_text(
        f'[updates]\non_start = false\nperiodic = false\n\n[appearance]\ntheme = "{theme}"\n')


def aika_running():
    k = c.WinDLL("kernel32", use_last_error=True)
    k.OpenMutexW.restype = c.c_void_p
    k.OpenMutexW.argtypes = [c.c_uint32, c.c_int, c.c_wchar_p]
    h = k.OpenMutexW(0x00100000, 0, "Local\\aika_single_instance")  # SYNCHRONIZE
    if h:
        k.CloseHandle(c.c_void_p(h))
    return bool(h)


def repaint_children(hwnd):
    """Wait until the date button has its label, then repaint every child window.

    The date picker is a child BUTTON that can lag the main paint; two identical
    frames are not proof it has painted, so do not rely on settling alone."""
    u = N.u
    u.FindWindowExW.argtypes = [c.c_void_p, c.c_void_p, c.c_wchar_p, c.c_wchar_p]
    u.FindWindowExW.restype = c.c_void_p
    u.RedrawWindow.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_uint]
    button = u.FindWindowExW(hwnd, None, "BUTTON", None)
    assert button, "date button not found"
    N.wait_for(lambda: N.get_text(button, 256).strip(), 5, "date button label")
    # RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    u.RedrawWindow(hwnd, None, None, 0x1 | 0x4 | 0x80 | 0x100)
    time.sleep(0.2)


def stable_frame(hwnd, cw, ch, timeout=8):
    """Park the cursor, then return unmasked pixels once two consecutive frames agree."""
    ps.move(hwnd, *NEUTRAL)
    previous, deadline = None, time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.15)
        pix = ps.grab(hwnd, cw, ch)
        masked = bytearray(pix)
        ps.mask_status_bar(masked, cw, ch)  # the clock ticks; compare without it
        if masked == previous:
            return pix
        previous = masked
    raise AssertionError("window never settled")


def zoom_to_view(hwnd, cw, ch):
    """Drag the overview bar's edge handles so the timeline shows exactly VIEW."""
    geo = ps.Geo(cw, ch)
    right = geo.chart_x + geo.chart_w
    bar_left, bar_right = geo.chart_x + 42, right - 148  # mirrors zoom_rects()
    y = geo.zoom_y + 4 + 13
    x_of = lambda hours: bar_left + int(hours / 24.0 * (bar_right - bar_left))
    want = (x_of(VIEW[0]), x_of(VIEW[1]))

    def selection():
        """(first, last) x of the selected range, read from the overview bar's pixels."""
        time.sleep(0.2)
        pix = ps.grab(hwnd, cw, ch)
        row = (y - 8) * cw * 4  # above the activity strip: only panel and selection colours
        px = lambda x: bytes(pix[row + x * 4:row + x * 4 + 3])
        diff = [x for x in range(bar_left + 6, bar_right - 6) if px(x) != px(bar_left + 10)]
        return (diff[0], diff[-1]) if diff else None

    # Synthetic drags race the app's message handling when sent back to back: pace
    # them and verify, resetting with "Full day" between attempts.
    for _ in range(4):
        for grab_x, target in [(bar_left + 2, want[0]), (bar_right - 2, want[1])]:
            N.send_msg(hwnd, N.WM_LBUTTONDOWN, 1, N.point(grab_x, y))
            time.sleep(0.1)
            N.send_msg(hwnd, N.WM_MOUSEMOVE, 1, N.point(target, y))
            time.sleep(0.1)
            N.send_msg(hwnd, N.WM_LBUTTONUP, 0, N.point(target, y))
            time.sleep(0.1)
        got = selection()
        if got and abs(got[0] - want[0]) <= 8 and abs(got[1] - want[1]) <= 8:
            return geo
        N.click_at(hwnd, right - 40, y)  # Full day
        time.sleep(0.2)
    raise AssertionError(f"could not zoom the timeline to {VIEW}: selection {got}, wanted {want}")


def capture_theme(exe, template, theme, cw, ch):
    with N.isolated_temp_dir(f"aika-shot-{theme}-") as folder:
        db = folder / "aika.db"
        shutil.copyfile(template, db)
        write_settings(folder, theme)
        process, hwnd = N.launch_app(exe, db)
        try:
            ps.set_client_size(hwnd, cw, ch)
            N.click_at(hwnd, *PREV_DAY_BUTTON)  # yesterday: the seeded day, no live tracking visible
            time.sleep(0.5)
            zoom_to_view(hwnd, cw, ch)
            repaint_children(hwnd)
            return stable_frame(hwnd, cw, ch)
        finally:
            N.ensure_closed(process, hwnd)


def compose_split(light, dark, cw, ch):
    """Light left / dark right of a "/" line crossing the window centre at the lanes' mid-height."""
    out = bytearray(len(light))
    geo = ps.Geo(cw, ch)
    y_mid = (geo.lane_y + geo.lanes_bottom) / 2.0  # the gap in the data is centred on the view
    for y in range(ch):
        edge = cw / 2.0 - 2 * SPLIT_SLANT * (y + 0.5 - y_mid)  # light where x < edge
        ix = max(0, min(cw, int(edge)))
        row = y * cw * 4
        out[row:row + ix * 4] = light[row:row + ix * 4]
        out[row + ix * 4:row + cw * 4] = dark[row + ix * 4:row + cw * 4]
        if 0 <= int(edge) < cw:
            f = edge - int(edge)  # share of the boundary pixel that is still light
            p = row + ix * 4
            for k in range(4):
                out[p + k] = round(light[p + k] * f + dark[p + k] * (1 - f))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=str(repo / "docs" / "screenshots"))
    ap.add_argument("--size", default="1320x860", help="client area in pixels, WxH")
    ap.add_argument("--exe", default=str(repo / "build" / "aika.exe"))
    ap.add_argument("--no-build", action="store_true", help="use the existing exe as is")
    args = ap.parse_args()
    cw, ch = (int(v) for v in args.size.lower().split("x"))
    out, exe = Path(args.out).resolve(), Path(args.exe).resolve()

    if aika_running():
        sys.exit("aika is already running: Exit it from the tray first (the GUI is single-instance).")
    if not args.no_build:
        # stdin=NUL: build.bat ends with `pause` on failure, which would otherwise hang.
        r = subprocess.run(["cmd", "/c", str(repo / "build.bat")], cwd=repo, stdin=subprocess.DEVNULL)
        if r.returncode:
            sys.exit("build failed")
    assert exe.exists(), f"missing {exe}"

    with N.isolated_temp_dir("aika-shot-template-") as folder:
        template = folder / "aika.db"
        write_settings(folder, "light")
        process, hwnd = N.launch_app(exe, template)  # creates the schema
        N.stop_app(process, hwnd)
        yesterday = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=1)
        seed(template, yesterday)
        light = capture_theme(exe, template, "light", cw, ch)
        dark = capture_theme(exe, template, "dark", cw, ch)

    out.mkdir(parents=True, exist_ok=True)
    ps.write_png(out / "aika-light.png", light, cw, ch)
    ps.write_png(out / "aika-dark.png", dark, cw, ch)
    ps.write_png(out / "aika-split.png", compose_split(light, dark, cw, ch), cw, ch)
    print(f"wrote aika-light.png, aika-dark.png, aika-split.png ({cw}x{ch}) to {out}")


if __name__ == "__main__":
    main()
