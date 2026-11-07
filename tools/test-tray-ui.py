"""Close-to-tray smoke test using an isolated database.

Run: python tools/test-tray-ui.py build/aika.exe
"""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
import sqlite3
import time
import native_ui as N

u = N.u
u.SetForegroundWindow.argtypes = [w.HWND]


class GuiThreadInfo(c.Structure):
    _fields_ = [("cbSize", w.DWORD), ("flags", w.DWORD),
                ("hwndActive", w.HWND), ("hwndFocus", w.HWND),
                ("hwndCapture", w.HWND), ("hwndMenuOwner", w.HWND),
                ("hwndMoveSize", w.HWND), ("hwndCaret", w.HWND), ("rcCaret", w.RECT)]


u.GetGUIThreadInfo.argtypes = [w.DWORD, c.POINTER(GuiThreadInfo)]


def check_menu(process, tray, owner, event=0x0205, select=None):
    N.post_msg(tray, 0x8001, 1, event)  # Shell right-button-up/context-menu callback
    N.wait_for(lambda: any(u.IsWindowVisible(h) for h in N.windows_for(process.pid, "#32768")),
               3, "tray menu opening")
    try:
        state = GuiThreadInfo(cbSize=c.sizeof(GuiThreadInfo))
        thread = u.GetWindowThreadProcessId(tray, None)
        assert u.GetGUIThreadInfo(thread, c.byref(state))
        assert state.hwndMenuOwner == owner, "Tray menu is owned by the wrong window"
        time.sleep(0.15)
        assert any(u.IsWindowVisible(h) for h in N.windows_for(process.pid, "#32768")), "Tray menu dismissed immediately"
        if select is not None:
            for _ in range(select + 1):
                N.post_msg(owner, 0x0100, 0x28, 0)  # Down
            N.post_msg(owner, 0x0100, 0x0D, 0)  # Enter executes the selected command.
            deadline = time.monotonic() + 3
            while any(u.IsWindowVisible(h) for h in N.windows_for(process.pid, "#32768")):
                assert time.monotonic() < deadline, "Tray command did not dismiss the menu"
                time.sleep(0.05)
    finally:
        if select is None:
            N.send_msg(owner, 0x001F, 0, 0)  # WM_CANCELMODE dismisses menu tracking
    time.sleep(0.1)


exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-tray-") as folder:
    db = folder / "test.db"
    process, hwnd = N.launch_app(exe, db)
    try:
        print("Window opened", flush=True)
        assert u.IsWindowVisible(hwnd)
        tray, = N.windows_for(process.pid, "aika_tray_window_class")
        u.SetForegroundWindow(hwnd)
        check_menu(process, tray, hwnd)
        check_menu(process, tray, hwnd, event=0x007B)  # WM_CONTEXTMENU
        check_menu(process, tray, hwnd, select=1)  # Settings command
        settings, = N.windows_for(process.pid, "aika_settings")
        check_menu(process, tray, settings)
        N.send_msg(settings, 0x0010, 0, 0)
        # A modal picker disables the main window, but must not disable the tray.
        N.click_at(hwnd, 450, 50)
        picker, = N.windows_for(process.pid, "aika_tag_picker")
        check_menu(process, tray, picker)
        N.send_msg(picker, 0x0010, 0, 0)
        N.send_msg(hwnd, 0x0010, 0, 0)  # WM_CLOSE
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
        N.send_msg(tray, 0x8001, 1, 0x0202)
        assert u.IsWindowVisible(hwnd), "Tray click did not restore the window"
        N.send_msg(hwnd, 0x0010, 0, 0)
        assert not u.IsWindowVisible(hwnd)
        N.send_msg(hwnd, 0x0111, 1001, 0)  # Open aika
        assert u.IsWindowVisible(hwnd)
        N.send_msg(hwnd, 0x0010, 0, 0)
        before_exit = time.time() * 1000
        check_menu(process, tray, tray, select=2)  # Exit from the actual menu
        process.wait(timeout=10)
        assert process.returncode == 0
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            end = conn.execute("SELECT MAX(EndUtcMs) FROM Activity WHERE TimelineId=2").fetchone()[0]
            assert end >= before_exit - 1000, "Exit did not flush tracking"
        print("PASS: stable tray menu with active/hidden/settings/picker windows, repeated opening, Settings/Exit commands, tracking/flush")
    finally:
        N.ensure_closed(process, hwnd)
