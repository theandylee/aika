"""Native splitter smoke test with an isolated database.

Run: python tools/test-panes-ui.py build/aika.exe
"""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
from datetime import datetime, timedelta
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
from native_ui import windows_for, window_pid

u = c.WinDLL("user32", use_last_error=True)
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.IsWindowVisible.argtypes = [w.HWND]
u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.MapWindowPoints.argtypes = [w.HWND, w.HWND, c.c_void_p, w.UINT]
u.UpdateWindow.argtypes = [w.HWND]
u.SetWindowPos.argtypes = [w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT]


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def point(x, y):
    return ((y & 0xffff) << 16) | (x & 0xffff)


def drag(hwnd, x, y, dx, dy, cancel=False):
    send(hwnd, 0x0201, 1, point(x, y))
    send(hwnd, 0x0200, 1, point(x + dx, y + dy))
    if cancel:
        send(hwnd, 0x0100, 0x1B)
    send(hwnd, 0x0202, 0, point(x + dx, y + dy))
    u.UpdateWindow(hwnd)


def launch(exe, db):
    process = subprocess.Popen([exe, "--db", str(db)])
    assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
    found = windows_for(process.pid, "aika_window_class")
    assert len(found) == 1
    # WaitForInputIdle can return before the first complete paint/timer tick.
    time.sleep(0.6)
    u.UpdateWindow(found[0])
    return process, found[0]


def scrollbars(hwnd):
    result = []

    for child in windows_for(window_pid(hwnd), "SCROLLBAR", hwnd):
        if u.IsWindowVisible(child):
            rect = w.RECT()
            u.GetWindowRect(child, c.byref(rect))
            u.MapWindowPoints(None, hwnd, c.byref(rect), 2)
            result.append((rect.left, rect.top, rect.right, rect.bottom))
    assert len(result) == 2, result
    return sorted(result)


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-panes-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process, hwnd = launch(exe, db)
    send(hwnd, 0x0111, 1002)  # Tray Exit (WM_CLOSE now hides).
    process.wait(timeout=10)
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    day = (today - datetime(2000, 1, 1)).days
    with closing(sqlite3.connect(db)) as conn:
        for i in range(50):
            group = conn.execute('INSERT INTO "Group" (TimelineId, DisplayName, Key) '
                                 'VALUES (3, ?, ?)', (f"Pane app {i}", f"pane-test-{i}")).lastrowid
            start = today + timedelta(minutes=i)
            end = start + timedelta(seconds=30)
            conn.execute('INSERT INTO Activity (TimelineId, DisplayName, GroupId, '
                         'StartLocalDate, EndLocalDate, StartLocalTime, EndLocalTime, '
                         'StartUtcTime, EndUtcTime, StartUtcMs, EndUtcMs) '
                         'VALUES (3, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                         (f"Pane row {i}", group, day, day, start.isoformat(), end.isoformat(),
                          start.isoformat(), end.isoformat(),
                          int(start.timestamp() * 1000), int(end.timestamp() * 1000)))
        conn.commit()
    process, hwnd = launch(exe, db)
    try:
        before = scrollbars(hwnd)
        # Default divider: list header begins at y=444, totals at x=991.
        drag(hwnd, 500, 440, 0, 90)
        taller = scrollbars(hwnd)
        assert taller[0][1] == before[0][1] + 90, (before, taller)
        assert taller[1][1] == before[1][1] + 90
        drag(hwnd, 987, 600, -100, 0)
        wider = scrollbars(hwnd)
        assert wider[0][0] == taller[0][0] - 100, (taller, wider)
        assert wider[1][0] == taller[1][0]
        drag(hwnd, 887, 600, 80, 0, cancel=True)
        assert scrollbars(hwnd) == wider, "Escape failed to restore widths"
        drag(hwnd, 500, 530, 0, -60, cancel=True)
        assert scrollbars(hwnd) == wider, "Escape failed to restore heights"
        # Capture loss also rolls back a live drag.
        send(hwnd, 0x0201, 1, point(887, 600))
        send(hwnd, 0x0200, 1, point(800, 600))
        send(hwnd, 0x001F)  # WM_CANCELMODE cancels a captured drag.
        time.sleep(0.1)
        u.UpdateWindow(hwnd)
        assert scrollbars(hwnd) == wider, ("Cancel mode failed to restore sizes", wider, scrollbars(hwnd))
        send(hwnd, 0x0201, 1, point(887, 600))
        send(hwnd, 0x0200, 1, point(800, 600))
        send(hwnd, 0x0215)  # WM_CAPTURECHANGED notification
        time.sleep(0.1)
        u.UpdateWindow(hwnd)
        assert scrollbars(hwnd) == wider, "Capture loss failed to restore sizes"
        u.SetWindowPos(hwnd, None, 0, 0, 720, 480, 0x0006)  # no move/z-order change
        u.UpdateWindow(hwnd)
        small = scrollbars(hwnd)
        assert all(r[3] > r[1] for r in small)
        print("PASS: timeline height, list/totals width, Escape, capture loss, window resize")
    finally:
        send(hwnd, 0x0111, 1002)
        process.wait(timeout=10)
