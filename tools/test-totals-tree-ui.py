"""Exercise totals hierarchy/folding with a temporary database."""
import ctypes as c
from contextlib import closing
from datetime import datetime, timedelta
import sqlite3
import native_ui as N

u = N.u


class ScrollInfo(c.Structure):
    _fields_ = [("size", c.c_uint), ("mask", c.c_uint), ("minimum", c.c_int),
                ("maximum", c.c_int), ("page", c.c_uint), ("position", c.c_int),
                ("track", c.c_int)]


from ctypes import wintypes as w
u.GetScrollInfo.argtypes = [w.HWND, c.c_int, c.POINTER(ScrollInfo)]


exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-totals-") as folder:
    db = folder / "test.db"
    process, hwnd = N.launch_app(exe, db)
    N.stop_app(process, hwnd)
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
    process, hwnd = N.launch_app(exe, db)
    try:
        N.click_at(hwnd, 20, 50)  # Previous day excludes the live tracker overlay.
        bars = N.windows_for(process.pid, "SCROLLBAR", hwnd)
        assert len(bars) == 2
        totals = bars[1]  # Created after the activity-list scrollbar.

        def rows():
            u.UpdateWindow(hwnd)
            info = ScrollInfo(size=c.sizeof(ScrollInfo), mask=1)
            assert u.GetScrollInfo(totals, 2, c.byref(info))
            return info.maximum + 1

        assert rows() == 32, rows()
        N.click_at(hwnd, 1295, 456)  # Header tree toggle.
        assert rows() == 3, rows()
        N.click_at(hwnd, 1050, 486)  # Work
        assert rows() == 4, rows()
        N.click_at(hwnd, 1050, 506)  # Project
        assert rows() == 34, rows()
        N.click_at(hwnd, 1050, 486)  # Fold Work, retaining nested state.
        assert rows() == 3, rows()
        N.click_at(hwnd, 1295, 456)
        assert rows() == 32
        N.click_at(hwnd, 1295, 456)
        assert rows() == 3
        N.click_at(hwnd, 1050, 486)
        assert rows() == 34, "Nested fold state was lost"
    finally:
        N.ensure_closed(process, hwnd)
print("PASS: flat/tree toggle, nested folding, row counts/scroll range, retained expansion")
