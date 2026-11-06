"""Check live theme switching and persistence using an isolated database."""
import ctypes as c
from ctypes import wintypes as w
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

u = c.WinDLL("user32")
g = c.WinDLL("gdi32")
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.GetDC.argtypes = [w.HWND]
u.GetDC.restype = w.HDC
u.ReleaseDC.argtypes = [w.HWND, w.HDC]
u.UpdateWindow.argtypes = [w.HWND]
g.GetPixel.argtypes = [w.HDC, c.c_int, c.c_int]
g.GetPixel.restype = w.DWORD


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def click(hwnd, x, y):
    point = (y << 16) | x
    send(hwnd, 0x0201, 1, point)
    send(hwnd, 0x0202, 0, point)
    u.UpdateWindow(hwnd)


def pixel(hwnd, x, y):
    u.UpdateWindow(hwnd)
    dc = u.GetDC(hwnd)
    try:
        return g.GetPixel(dc, x, y)
    finally:
        u.ReleaseDC(hwnd, dc)


def launch(exe, db):
    process = subprocess.Popen([exe, "--db", str(db)])
    assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
    found = []

    @callback
    def visit(hwnd, _):
        pid = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(pid))
        name = c.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, name, 256)
        if pid.value == process.pid and name.value == "aika_window_class":
            found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    assert len(found) == 1
    time.sleep(0.6)
    return process, found[0]


def stop(process, hwnd):
    send(hwnd, 0x0111, 1002)
    assert process.wait(timeout=10) == 0


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-theme-", dir=root) as folder:
    db = Path(folder) / "test.db"
    preference = Path(str(db) + ".theme")
    for initial, expected in [(None, 0xFFFFFF), ("dark", 0x282320), ("light", 0xFFFFFF)]:
        process, hwnd = launch(exe, db)
        try:
            assert pixel(hwnd, 500, 40) == expected, (initial, hex(pixel(hwnd, 500, 40)))
            # Release outside must not activate the switch.
            send(hwnd, 0x0201, 1, (12 << 16) | 1298)
            send(hwnd, 0x0202, 0, (40 << 16) | 1100)
            assert pixel(hwnd, 500, 40) == expected
            click(hwnd, 1298, 12)
            target = "light" if initial == "dark" else "dark"
            assert preference.read_text() == target
            assert pixel(hwnd, 500, 40) == (0xFFFFFF if target == "light" else 0x282320)
            # Switch works on placeholder tabs too.
            click(hwnd, 90, 12)
            click(hwnd, 1298, 12)
            assert preference.read_text() == ("dark" if target == "light" else "light")
            click(hwnd, 1298, 12)
        finally:
            stop(process, hwnd)
    preference.write_text("invalid")
    process, hwnd = launch(exe, db)
    try:
        assert pixel(hwnd, 500, 40) == 0xFFFFFF
    finally:
        stop(process, hwnd)
print("PASS: light/dark pixels, cancelled click, tab switching, persistence, invalid preference")
