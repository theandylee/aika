"""Check live theme switching and persistence using an isolated database."""
import ctypes as c
from ctypes import wintypes as w
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from native_ui import windows_for, find_window, window_pid

u = c.WinDLL("user32")
g = c.WinDLL("gdi32")
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.GetDC.argtypes = [w.HWND]
u.GetDC.restype = w.HDC
u.ReleaseDC.argtypes = [w.HWND, w.HDC]
u.UpdateWindow.argtypes = [w.HWND]
u.FindWindowExW.argtypes = [w.HWND, w.HWND, w.LPCWSTR, w.LPCWSTR]
u.FindWindowExW.restype = w.HWND
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
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
    found = windows_for(process.pid, "aika_window_class")
    assert len(found) == 1
    time.sleep(0.6)
    return process, found[0]


def stop(process, hwnd):
    send(hwnd, 0x0111, 1002)
    assert process.wait(timeout=10) == 0, process.returncode


def check_calendar(hwnd, dark):
    picker = u.FindWindowExW(hwnd, None, "BUTTON", None)
    assert picker
    assert pixel(picker, 210, 13) == (0x382F28 if dark else 0xFFFFFF), "Date button face has wrong color"
    label = c.create_unicode_buffer(256)
    u.GetWindowTextW(picker, label, 256)
    assert len(label.value.split()) == 4, label.value  # weekday, day, month, year
    for _ in range(2):  # Reopening must preserve the palette.
        send(picker, 0x00F5)  # BM_CLICK opens the custom calendar popup.
        time.sleep(0.15)
        popup = find_window(window_pid(hwnd), "aika_date_popup")
        calendar = u.FindWindowExW(popup, None, "SysMonthCal32", None)
        assert calendar, "Calendar did not open"
        u.UpdateWindow(calendar)
        assert send(calendar, 0x100B, 4) == (0x282320 if dark else 0xFFFFFF)
        assert send(calendar, 0x100B, 1) == (0xF0E8E0 if dark else 0x28221E)
        if dark:
            # Confirm the actual rendered month uses the dark background.
            colors = [pixel(calendar, x, y) for x in range(12, 140, 8) for y in range(45, 120, 8)]
            assert colors.count(0x282320) > 30, ("Calendar did not paint the dark palette", {hex(v): colors.count(v) for v in set(colors)})
        send(popup, 0x0010)  # Cancel without navigating.
    # Selecting a different date updates the label; Escape does not commit.
    for key, commit in [(0x1B, False), (0x0D, True)]:
        send(picker, 0x00F5)
        u.PostMessageW(calendar, 0x0100, 0x27, 0)  # Right moves selection one day.
        u.PostMessageW(calendar, 0x0100, key, 0)
        time.sleep(0.15)
        updated = c.create_unicode_buffer(256)
        u.GetWindowTextW(picker, updated, 256)
        assert (updated.value != label.value) == commit, (label.value, updated.value, commit)


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-theme-", dir=root) as folder:
    db = Path(folder) / "test.db"
    preference = Path(str(db) + ".theme")
    for initial, expected in [(None, 0xFFFFFF), ("dark", 0x282320), ("light", 0xFFFFFF)]:
        process, hwnd = launch(exe, db)
        try:
            assert pixel(hwnd, 600, 40) == expected, (initial, hex(pixel(hwnd, 600, 40)))
            assert pixel(hwnd, 100, 411) == (0x20415A if initial == "dark" else 0xA8DDFF)
            # Release outside must not activate the switch.
            send(hwnd, 0x0201, 1, (12 << 16) | 1298)
            send(hwnd, 0x0202, 0, (40 << 16) | 1100)
            assert pixel(hwnd, 600, 40) == expected
            click(hwnd, 1298, 12)
            target = "light" if initial == "dark" else "dark"
            assert preference.read_text() == target
            assert pixel(hwnd, 600, 40) == (0xFFFFFF if target == "light" else 0x282320)
            assert pixel(hwnd, 100, 411) == (0xA8DDFF if target == "light" else 0x20415A)
            check_calendar(hwnd, target == "dark")
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
        assert pixel(hwnd, 600, 40) == 0xFFFFFF
    finally:
        stop(process, hwnd)
print("PASS: theme/zoom/date-button/calendar colors, date selection/cancel, tab switching, theme persistence")
