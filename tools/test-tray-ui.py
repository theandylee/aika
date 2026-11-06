"""Close-to-tray smoke test using an isolated database.

Run: python tools/test-tray-ui.py build/aika.exe
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
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.IsWindowVisible.argtypes = [w.HWND]
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SetForegroundWindow.argtypes = [w.HWND]
class GuiThreadInfo(c.Structure):
    _fields_ = [("cbSize", w.DWORD), ("flags", w.DWORD),
                ("hwndActive", w.HWND), ("hwndFocus", w.HWND),
                ("hwndCapture", w.HWND), ("hwndMenuOwner", w.HWND),
                ("hwndMoveSize", w.HWND), ("hwndCaret", w.HWND), ("rcCaret", w.RECT)]


u.GetGUIThreadInfo.argtypes = [w.DWORD, c.POINTER(GuiThreadInfo)]


def windows_for(pid, class_name):
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
    return found


def check_menu(process, tray, owner, event=0x0205, select=None):
    u.PostMessageW(tray, 0x8001, 1, event)  # Shell right-button-up/context-menu callback
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if any(u.IsWindowVisible(h) for h in windows_for(process.pid, "#32768")):
            break
        time.sleep(0.05)
    else:
        raise AssertionError("Tray menu did not open")
    try:
        state = GuiThreadInfo(cbSize=c.sizeof(GuiThreadInfo))
        thread = u.GetWindowThreadProcessId(tray, None)
        assert u.GetGUIThreadInfo(thread, c.byref(state))
        assert state.hwndMenuOwner == owner, "Tray menu is owned by the wrong window"
        time.sleep(0.15)
        assert any(u.IsWindowVisible(h) for h in windows_for(process.pid, "#32768")), "Tray menu dismissed immediately"
        if select is not None:
            for _ in range(select + 1):
                u.PostMessageW(owner, 0x0100, 0x28, 0)  # Down
            u.PostMessageW(owner, 0x0100, 0x0D, 0)  # Enter executes the selected command.
            deadline = time.monotonic() + 3
            while any(u.IsWindowVisible(h) for h in windows_for(process.pid, "#32768")):
                assert time.monotonic() < deadline, "Tray command did not dismiss the menu"
                time.sleep(0.05)
    finally:
        if select is None:
            u.SendMessageW(owner, 0x001F, 0, 0)  # WM_CANCELMODE dismisses menu tracking
    time.sleep(0.1)

exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-tray-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
        found = []

        @callback
        def visit(window, _):
            pid = w.DWORD()
            u.GetWindowThreadProcessId(window, c.byref(pid))
            name = c.create_unicode_buffer(256)
            u.GetClassNameW(window, name, 256)
            if pid.value == process.pid and name.value == "aika_window_class":
                found.append(window)
            return True

        u.EnumWindows(visit, 0)
        assert len(found) == 1
        hwnd = found[0]
        print("Window opened", flush=True)
        assert u.IsWindowVisible(hwnd)
        tray, = windows_for(process.pid, "aika_tray_window_class")
        u.SetForegroundWindow(hwnd)
        check_menu(process, tray, hwnd)
        check_menu(process, tray, hwnd, event=0x007B)  # WM_CONTEXTMENU
        check_menu(process, tray, hwnd, select=1)  # Settings command
        settings, = windows_for(process.pid, "aika_settings")
        check_menu(process, tray, settings)
        u.SendMessageW(settings, 0x0010, 0, 0)
        # A modal picker disables the main window, but must not disable the tray.
        u.SendMessageW(hwnd, 0x0201, 1, (50 << 16) | 450)
        u.SendMessageW(hwnd, 0x0202, 0, (50 << 16) | 450)
        picker, = windows_for(process.pid, "aika_tag_picker")
        check_menu(process, tray, picker)
        u.SendMessageW(picker, 0x0010, 0, 0)
        u.SendMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
        assert not u.IsWindowVisible(hwnd), "Close did not hide the window"
        assert process.poll() is None, "Close terminated the process"
        check_menu(process, tray, tray)
        print("Window hidden; checking background tracking", flush=True)
        time.sleep(12)
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            end = conn.execute("SELECT MAX(EndUtcMs) FROM Activity WHERE TimelineId=2").fetchone()[0]
            assert end is not None and end > (time.time() - 5) * 1000, "Tracking stopped in tray"
        # Deliver the shell's icon left-click callback.
        print("Background tracking verified; checking restore", flush=True)
        u.SendMessageW(tray, 0x8001, 1, 0x0202)
        assert u.IsWindowVisible(hwnd), "Tray click did not restore the window"
        u.SendMessageW(hwnd, 0x0010, 0, 0)
        assert not u.IsWindowVisible(hwnd)
        u.SendMessageW(hwnd, 0x0111, 1001, 0)  # Open aika
        assert u.IsWindowVisible(hwnd)
        u.SendMessageW(hwnd, 0x0010, 0, 0)
        before_exit = time.time() * 1000
        check_menu(process, tray, tray, select=2)  # Exit from the actual menu
        process.wait(timeout=10)
        assert process.returncode == 0
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            end = conn.execute("SELECT MAX(EndUtcMs) FROM Activity WHERE TimelineId=2").fetchone()[0]
            assert end >= before_exit - 1000, "Exit did not flush tracking"
        print("PASS: stable tray menu with active/hidden/settings/picker windows, repeated opening, Settings/Exit commands, tracking/flush")
    finally:
        if process.poll() is None:
            if hwnd:
                u.SendMessageW(hwnd, 0x0111, 1002, 0)
            process.wait(timeout=10)
