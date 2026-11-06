"""Task toolbar smoke test in an isolated process/database.

Run: python tools/test-task-ui.py build/aika-task.exe
"""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

u = c.WinDLL("user32", use_last_error=True)
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]


def find(pid, class_name):
    found = []

    @callback
    def visit(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        name = c.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, name, 256)
        if owner.value == pid and name.value == class_name:
            found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    return found[0] if found else None


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika-task.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-task-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
        hwnd = find(process.pid, "aika_window_class")
        assert hwnd

        def click_task():
            # Task button follows the 232px date picker (client x=388..520).
            point = (50 << 16) | 450
            send(hwnd, 0x0201, 1, point)
            send(hwnd, 0x0202, 0, point)

        def rows():
            with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
                return conn.execute("SELECT ActivityId, GroupId, StartUtcMs, EndUtcMs FROM Activity "
                                    "WHERE TimelineId=1 ORDER BY ActivityId").fetchall()

        click_task()
        popup = find(process.pid, "aika_tag_picker")
        assert popup
        send(popup, 0x0010)
        assert rows() == [], "Cancel must not start a task"

        click_task()
        popup = find(process.pid, "aika_tag_picker")
        name = c.create_unicode_buffer("Task smoke")
        send(u.GetDlgItem(popup, 101), 0x000C, 0, c.addressof(name))
        send(popup, 0x0111, 104, u.GetDlgItem(popup, 104))
        first = rows()
        assert len(first) == 1
        time.sleep(2.5)
        growing = rows()
        assert growing[0][3] > first[0][3] + 1000
        click_task()
        stopped = rows()
        time.sleep(1.5)
        assert rows() == stopped, "Stopped block must not grow"

        click_task()
        popup = find(process.pid, "aika_tag_picker")
        send(popup, 0x0111, 103, u.GetDlgItem(popup, 103))
        second = rows()
        assert len(second) == 2 and second[0][1] == second[1][1]
        send(hwnd, 0x0010)  # Hide in tray, not exit.
        time.sleep(2.5)
        assert rows()[1][3] > second[1][3] + 1000
        send(hwnd, 0x0111, 1002, 0)  # Tray Exit flushes the running task.
        process.wait(timeout=10)
        final = rows()
        assert final[0] == stopped[0] and final[1][3] >= second[1][3]
        print("PASS: picker cancel, create/reuse, live growth, stop, tray tracking, exit flush")
    finally:
        if process.poll() is None:
            if hwnd:
                send(hwnd, 0x0111, 1002, 0)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
