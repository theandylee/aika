"""Exercise totals hierarchy/folding with a temporary database."""
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
from native_ui import windows_for as find

u = c.WinDLL("user32")
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.UpdateWindow.argtypes = [w.HWND]


class ScrollInfo(c.Structure):
    _fields_ = [("size", w.UINT), ("mask", w.UINT), ("minimum", c.c_int),
                ("maximum", c.c_int), ("page", w.UINT), ("position", c.c_int),
                ("track", c.c_int)]


u.GetScrollInfo.argtypes = [w.HWND, c.c_int, c.POINTER(ScrollInfo)]


def launch(exe, db):
    process = subprocess.Popen([exe, "--db", str(db)])
    assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
    hwnd, = find(process.pid, "aika_window_class")
    time.sleep(0.6)
    return process, hwnd


def click(hwnd, x, y):
    point = (y << 16) | x
    u.SendMessageW(hwnd, 0x0201, 1, point)
    u.SendMessageW(hwnd, 0x0202, 0, point)
    u.UpdateWindow(hwnd)


def stop(process, hwnd):
    u.SendMessageW(hwnd, 0x0111, 1002, 0)
    assert process.wait(timeout=10) == 0


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-totals-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process, hwnd = launch(exe, db)
    stop(process, hwnd)
    yesterday = datetime.now().replace(hour=12, minute=0, second=0, microsecond=0) - timedelta(days=1)
    day = (yesterday.replace(hour=0) - datetime(2000, 1, 1)).days
    names = [f"Work/Project/Task {i}" for i in range(30)] + ["Personal/Read", "Loose"]
    with closing(sqlite3.connect(db)) as conn:
        for i, name in enumerate(names):
            group = conn.execute('INSERT INTO "Group" (TimelineId, DisplayName, Key) VALUES (3, ?, ?)',
                                 (name, f"tree-{i}")).lastrowid
            start = yesterday + timedelta(minutes=i)
            end = start + timedelta(minutes=1)
            conn.execute('INSERT INTO Activity (TimelineId, DisplayName, GroupId, '
                         'StartLocalDate, EndLocalDate, StartLocalTime, EndLocalTime, '
                         'StartUtcTime, EndUtcTime, StartUtcMs, EndUtcMs) VALUES (3, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                         (name, group, day, day, start.isoformat(), end.isoformat(), start.isoformat(),
                          end.isoformat(), int(start.timestamp() * 1000), int(end.timestamp() * 1000)))
        conn.commit()
    process, hwnd = launch(exe, db)
    try:
        click(hwnd, 20, 50)  # Previous day excludes the live tracker overlay.
        bars = find(process.pid, "SCROLLBAR", hwnd)
        assert len(bars) == 2
        totals = bars[1]  # Created after the activity-list scrollbar.

        def rows():
            u.UpdateWindow(hwnd)
            info = ScrollInfo(size=c.sizeof(ScrollInfo), mask=1)
            assert u.GetScrollInfo(totals, 2, c.byref(info))
            return info.maximum + 1

        assert rows() == 32, rows()
        click(hwnd, 1295, 456)  # Header tree toggle.
        assert rows() == 3, rows()
        click(hwnd, 1050, 486)  # Work
        assert rows() == 4, rows()
        click(hwnd, 1050, 506)  # Project
        assert rows() == 34, rows()
        click(hwnd, 1050, 486)  # Fold Work, retaining nested state.
        assert rows() == 3, rows()
        click(hwnd, 1295, 456)
        assert rows() == 32
        click(hwnd, 1295, 456)
        assert rows() == 3
        click(hwnd, 1050, 486)
        assert rows() == 34, "Nested fold state was lost"
    finally:
        stop(process, hwnd)
print("PASS: flat/tree toggle, nested folding, row counts/scroll range, retained expansion")
