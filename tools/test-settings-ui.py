"""Exercise Tracking settings against an isolated database (no real input injection)."""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

u = c.WinDLL("user32")
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.IsWindowEnabled.argtypes = [w.HWND]
u.IsWindow.argtypes = [w.HWND]
u.GetClientRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def find(pid, cls):
    found = []

    @callback
    def visit(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        name = c.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, name, 256)
        if owner.value == pid and name.value == cls:
            found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    return found[0] if found else None


def wait_for(pid, cls):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        hwnd = find(pid, cls)
        if hwnd:
            return hwnd
        time.sleep(0.05)
    raise AssertionError(f"Missing window: {cls}")


def text(hwnd):
    buf = c.create_unicode_buffer(64)
    send(hwnd, 0xD, 64, c.addressof(buf))  # WM_GETTEXT across processes
    return buf.value


def set_text(hwnd, value):
    buf = c.create_unicode_buffer(value)
    send(hwnd, 0xC, 0, c.addressof(buf))  # WM_SETTEXT across processes


def wait_closed(hwnd):
    deadline = time.monotonic() + 5
    while u.IsWindow(hwnd) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not u.IsWindow(hwnd), "Settings did not close"


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
with tempfile.TemporaryDirectory(prefix="aika-settings-", dir=Path(tempfile.gettempdir()) / "opencode") as directory:
    db = Path(directory) / "test.db"
    preference = Path(str(db) + ".settings")
    for theme in ["light", "dark"]:
        Path(str(db) + ".theme").write_text(theme)
        process = subprocess.Popen([exe, "--db", str(db)])
        hwnd = None
        try:
            u.WaitForInputIdle(w.HANDLE(process._handle), 10000)
            hwnd = wait_for(process.pid, "aika_window_class")

            def open_settings():
                send(hwnd, 0x111, 1003)
                popup = wait_for(process.pid, "aika_settings")
                assert not u.IsWindowEnabled(hwnd)

                parent_rect, popup_rect = w.RECT(), w.RECT()
                u.GetWindowRect(hwnd, c.byref(parent_rect))
                u.GetWindowRect(popup, c.byref(popup_rect))
                assert abs(parent_rect.left + parent_rect.right - popup_rect.left - popup_rect.right) <= 1
                assert abs(parent_rect.top + parent_rect.bottom - popup_rect.top - popup_rect.bottom) <= 1
                return popup, u.GetDlgItem(popup, 101)

            popup, edit = open_settings()
            assert text(edit) == ("1" if theme == "light" else "500")
            # Cancel and title-bar close must leave preferences unchanged.
            before = preference.read_bytes() if preference.exists() else None
            set_text(edit, "9")
            send(popup, 0x111, 2)
            assert u.IsWindowEnabled(hwnd) and not u.IsWindow(popup)
            assert (preference.read_bytes() if preference.exists() else None) == before
            popup, edit = open_settings()
            set_text(edit, "8")
            send(popup, 0x10)
            assert (preference.read_bytes() if preference.exists() else None) == before

            # The visible Settings button opens the same window; Escape cancels.
            rect = w.RECT()
            u.GetClientRect(hwnd, c.byref(rect))
            point = (12 << 16) | (rect.right - 56)
            send(hwnd, 0x201, 1, point)
            send(hwnd, 0x202, 0, point)
            popup = wait_for(process.pid, "aika_settings")
            edit = u.GetDlgItem(popup, 101)
            set_text(edit, "7")
            u.PostMessageW(edit, 0x100, 0x1B, 0)
            wait_closed(popup)
            assert (preference.read_bytes() if preference.exists() else None) == before

            for invalid in ["0", "501", ""]:
                popup, edit = open_settings()
                set_text(edit, invalid)
                assert text(edit) == invalid, (invalid, text(edit))
                u.PostMessageW(u.GetDlgItem(popup, 1), 0xF5, 0, 0)  # BM_CLICK
                warning = wait_for(process.pid, "#32770")
                send(warning, 0x111, 1)
                assert u.IsWindow(popup)
                assert (preference.read_bytes() if preference.exists() else None) == before
                send(popup, 0x111, 2)

            for value in ["1", "500"]:
                popup, edit = open_settings()
                set_text(edit, value)
                u.PostMessageW(edit, 0x100, 0xD, 0)  # Enter commits.
                wait_closed(popup)
                assert preference.read_text().strip() == value
                popup, edit = open_settings()
                assert text(edit) == value
                send(popup, 0x111, 2)

            # The owner timer must keep extending activity while settings is open.
            popup, edit = open_settings()
            deadline = time.monotonic() + 16
            while True:
                with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as connection:
                    extended = connection.execute(
                        "select count(*) from Activity where TimelineId=2 and EndUtcMs-StartUtcMs>=9000"
                    ).fetchone()[0] > 0
                if extended:
                    break
                assert time.monotonic() < deadline, "Tracking timer stopped while settings was open"
                time.sleep(0.25)
            send(popup, 0x111, 2)

            # A failed write leaves the editor open and the existing value active.
            saved = preference.read_bytes()
            preference.unlink()
            preference.mkdir()
            try:
                popup, edit = open_settings()
                set_text(edit, "2")
                u.PostMessageW(u.GetDlgItem(popup, 1), 0xF5, 0, 0)
                warning = wait_for(process.pid, "#32770")
                send(warning, 0x111, 1)
                assert u.IsWindow(popup)
                send(popup, 0x111, 2)
                popup, edit = open_settings()
                assert text(edit) == "500"
                send(popup, 0x111, 2)
            finally:
                preference.rmdir()
                preference.write_bytes(saved)
        finally:
            if hwnd:
                send(hwnd, 0x111, 1002)
                assert process.wait(timeout=10) == 0
            elif process.poll() is None:
                process.terminate()
                process.wait(timeout=10)

    preference.write_text("invalid")
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        u.WaitForInputIdle(w.HANDLE(process._handle), 10000)
        hwnd = wait_for(process.pid, "aika_window_class")
        send(hwnd, 0x111, 1003)
        popup = wait_for(process.pid, "aika_settings")
        assert text(u.GetDlgItem(popup, 101)) == "1"
        send(popup, 0x111, 2)
    finally:
        if hwnd:
            send(hwnd, 0x111, 1002)
        else:
            process.terminate()
        assert process.wait(timeout=10) == 0
print("PASS: settings validation, save/cancel/close, restart persistence, light/dark, tracking while open")
