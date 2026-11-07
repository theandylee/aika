"""Check live theme switching and persistence using an isolated database."""
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
import time
import native_ui as N

u = N.u
g = c.WinDLL("gdi32")
u.GetDC.argtypes = [w.HWND]
u.GetDC.restype = w.HDC
u.ReleaseDC.argtypes = [w.HWND, w.HDC]
u.FindWindowExW.argtypes = [w.HWND, w.HWND, w.LPCWSTR, w.LPCWSTR]
u.FindWindowExW.restype = w.HWND
g.GetPixel.argtypes = [w.HDC, c.c_int, c.c_int]
g.GetPixel.restype = w.DWORD


def pixel(hwnd, x, y):
    u.UpdateWindow(hwnd)
    dc = u.GetDC(hwnd)
    try:
        return g.GetPixel(dc, x, y)
    finally:
        u.ReleaseDC(hwnd, dc)


def check_calendar(hwnd, dark):
    picker = u.FindWindowExW(hwnd, None, "BUTTON", None)
    assert picker
    assert pixel(picker, 210, 13) == (0x382F28 if dark else 0xFFFFFF), "Date button face has wrong color"
    label = c.create_unicode_buffer(256)
    u.GetWindowTextW(picker, label, 256)
    assert len(label.value.split()) == 4, label.value  # weekday, day, month, year
    for _ in range(2):  # Reopening must preserve the palette.
        N.send_msg(picker, 0x00F5)  # BM_CLICK opens the custom calendar popup.
        time.sleep(0.15)
        popup = N.find_window(N.window_pid(hwnd), "aika_date_popup")
        calendar = u.FindWindowExW(popup, None, "SysMonthCal32", None)
        assert calendar, "Calendar did not open"
        u.UpdateWindow(calendar)
        assert N.send_msg(calendar, 0x100B, 4) == (0x282320 if dark else 0xFFFFFF)
        assert N.send_msg(calendar, 0x100B, 1) == (0xF0E8E0 if dark else 0x28221E)
        if dark:
            # Confirm the actual rendered month uses the dark background.
            colors = [pixel(calendar, x, y) for x in range(12, 140, 8) for y in range(45, 120, 8)]
            assert colors.count(0x282320) > 30, ("Calendar did not paint the dark palette", {hex(v): colors.count(v) for v in set(colors)})
        N.send_msg(popup, 0x0010)  # Cancel without navigating.
    # Selecting a different date updates the label; Escape does not commit.
    for key, commit in [(0x1B, False), (0x0D, True)]:
        N.send_msg(picker, 0x00F5)
        N.post_msg(calendar, 0x0100, 0x27, 0)  # Right moves selection one day.
        N.post_msg(calendar, 0x0100, key, 0)
        time.sleep(0.15)
        updated = c.create_unicode_buffer(256)
        u.GetWindowTextW(picker, updated, 256)
        assert (updated.value != label.value) == commit, (label.value, updated.value, commit)


exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-theme-") as folder:
    db = folder / "test.db"
    preference = Path(str(db) + ".theme")
    for initial, expected in [(None, 0xFFFFFF), ("dark", 0x282320), ("light", 0xFFFFFF)]:
        process, hwnd = N.launch_app(exe, db)
        try:
            assert pixel(hwnd, 600, 40) == expected, (initial, hex(pixel(hwnd, 600, 40)))
            assert pixel(hwnd, 100, 411) == (0x20415A if initial == "dark" else 0xA8DDFF)
            # Release outside must not activate the switch.
            N.send_msg(hwnd, 0x0201, 1, N.point(1298, 12))
            N.send_msg(hwnd, 0x0202, 0, N.point(1100, 40))
            assert pixel(hwnd, 600, 40) == expected
            N.click_at(hwnd, 1298, 12)
            target = "light" if initial == "dark" else "dark"
            assert preference.read_text() == target
            assert pixel(hwnd, 600, 40) == (0xFFFFFF if target == "light" else 0x282320)
            assert pixel(hwnd, 100, 411) == (0xA8DDFF if target == "light" else 0x20415A)
            check_calendar(hwnd, target == "dark")
            # Switch works on placeholder tabs too.
            N.click_at(hwnd, 90, 12)
            N.click_at(hwnd, 1298, 12)
            assert preference.read_text() == ("dark" if target == "light" else "light")
            N.click_at(hwnd, 1298, 12)
        finally:
            N.stop_app(process, hwnd)
    preference.write_text("invalid")
    process, hwnd = N.launch_app(exe, db)
    try:
        assert pixel(hwnd, 600, 40) == 0xFFFFFF
    finally:
        N.stop_app(process, hwnd)
print("PASS: theme/zoom/date-button/calendar colors, date selection/cancel, tab switching, theme persistence")
