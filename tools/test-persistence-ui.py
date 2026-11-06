"""Check lock responsiveness, visible save errors, and cancelled Exit in isolation.

Run: python tools/test-persistence-ui.py build/aika.exe
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
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageTimeoutW.argtypes = [
    w.HWND, w.UINT, w.WPARAM, w.LPARAM, w.UINT, w.UINT, c.POINTER(c.c_size_t)
]
u.SendMessageTimeoutW.restype = c.c_size_t


def find(pid, class_name):
    found = []

    @callback
    def visit(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        name = c.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, name, len(name))
        if owner.value == pid and name.value == class_name:
            found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    return found[0] if found else None


def title(hwnd):
    text = c.create_unicode_buffer(512)
    u.GetWindowTextW(hwnd, text, len(text))
    return text.value


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for persistence UI state")


def responsive_tick(hwnd):
    result = c.c_size_t()
    assert u.SendMessageTimeoutW(hwnd, 0x0113, 1, 0, 2, 1000, c.byref(result)), (
        "The main thread blocked on database contention"
    )


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-persistence-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
        hwnd = wait_for(lambda: find(process.pid, "aika_window_class"))
        # Hold the SQLite writer lock, without blocking WAL readers. No real
        # foreground/idle input is injected; the usage endpoint eventually writes
        # whether the user's session is Active or Away.
        with closing(sqlite3.connect(db, timeout=1)) as blocker:
            blocker.execute("BEGIN IMMEDIATE")
            wait_for(lambda: "Tracking save error" in title(hwnd))
            for _ in range(3):
                responsive_tick(hwnd)
                time.sleep(0.55)
            # Post, rather than synchronously send: cancelled Exit presents a
            # native message box. Locate it strictly within this process.
            u.PostMessageW(hwnd, 0x0111, 1002, 0)
            popup = wait_for(lambda: find(process.pid, "#32770"))
            assert process.poll() is None, "Exit must not discard pending writes"
            assert "Exit cancelled" in title(u.GetDlgItem(popup, 65535)), title(popup)
            u.PostMessageW(popup, 0x0010, 0, 0)  # Dismiss the acknowledgement box.
            wait_for(lambda: find(process.pid, "#32770") is None)
            assert "Tracking save error" in title(hwnd)
            blocker.rollback()
        wait_for(lambda: title(hwnd) == "aika")
        responsive_tick(hwnd)
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            count = conn.execute("SELECT count(*) FROM Activity WHERE TimelineId=2").fetchone()[0]
            assert count >= 2, "Both finalized and resumed usage must survive recovery"
            assert conn.execute(
                "SELECT count(*) FROM Activity WHERE TimelineId=2 AND EndUtcMs < StartUtcMs"
            ).fetchone()[0] == 0
        u.PostMessageW(hwnd, 0x0111, 1002, 0)
        process.wait(timeout=10)
        assert process.returncode == 0
        print("PASS: lock responsiveness, visible error, cancelled Exit, retry recovery, clean Exit")
    finally:
        if process.poll() is None:
            popup = find(process.pid, "#32770")
            if popup:
                u.PostMessageW(popup, 0x0010, 0, 0)
            if hwnd:
                u.PostMessageW(hwnd, 0x0111, 1002, 0)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
