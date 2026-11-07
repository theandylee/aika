"""Exercise Tracking settings against an isolated database (no real input injection)."""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
from pathlib import Path
import sqlite3
import time
import native_ui as N

u = N.u
u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.GetClientRect.argtypes = [w.HWND, c.POINTER(w.RECT)]


def wait_for(pid, cls):
    return N.wait_for(lambda: N.find_window(pid, cls), 5, f"window: {cls}")


def text(hwnd):
    return N.get_text(hwnd)


def set_text(hwnd, value):
    N.set_text(hwnd, value)


def wait_closed(hwnd):
    N.wait_closed(hwnd)


exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-settings-") as directory:
    db = directory / "test.db"
    preference = Path(str(db) + ".settings")
    for theme in ["light", "dark"]:
        Path(str(db) + ".theme").write_text(theme)
        process, hwnd = N.launch_app(exe, db, settle=0)
        try:
            def open_settings():
                N.send_msg(hwnd, 0x111, 1003)
                popup = wait_for(process.pid, "aika_settings")
                assert not u.IsWindowEnabled(hwnd)

                parent_rect, popup_rect = w.RECT(), w.RECT()
                u.GetWindowRect(hwnd, c.byref(parent_rect))
                u.GetWindowRect(popup, c.byref(popup_rect))
                assert abs(parent_rect.left + parent_rect.right - popup_rect.left - popup_rect.right) <= 1
                assert abs(parent_rect.top + parent_rect.bottom - popup_rect.top - popup_rect.bottom) <= 1
                return popup, N.dlg_item(popup, 101)

            popup, edit = open_settings()
            assert text(edit) == ("1" if theme == "light" else "500")
            # Cancel and title-bar close must leave preferences unchanged.
            before = preference.read_bytes() if preference.exists() else None
            set_text(edit, "9")
            N.send_msg(popup, 0x111, 2)
            assert u.IsWindowEnabled(hwnd) and not u.IsWindow(popup)
            assert (preference.read_bytes() if preference.exists() else None) == before
            popup, edit = open_settings()
            set_text(edit, "8")
            N.send_msg(popup, 0x10)
            assert (preference.read_bytes() if preference.exists() else None) == before

            # The visible Settings button opens the same window; Escape cancels.
            rect = w.RECT()
            u.GetClientRect(hwnd, c.byref(rect))
            N.send_msg(hwnd, 0x201, 1, N.point(rect.right - 56, 12))
            N.send_msg(hwnd, 0x202, 0, N.point(rect.right - 56, 12))
            popup = wait_for(process.pid, "aika_settings")
            edit = N.dlg_item(popup, 101)
            set_text(edit, "7")
            N.post_msg(edit, 0x100, 0x1B, 0)
            wait_closed(popup)
            assert (preference.read_bytes() if preference.exists() else None) == before

            for invalid in ["0", "501", ""]:
                popup, edit = open_settings()
                set_text(edit, invalid)
                assert text(edit) == invalid, (invalid, text(edit))
                N.post_msg(N.dlg_item(popup, 1), 0xF5, 0, 0)  # BM_CLICK
                warning = wait_for(process.pid, "#32770")
                N.send_msg(warning, 0x111, 1)
                assert u.IsWindow(popup)
                assert (preference.read_bytes() if preference.exists() else None) == before
                N.send_msg(popup, 0x111, 2)

            for value in ["1", "500"]:
                popup, edit = open_settings()
                set_text(edit, value)
                N.post_msg(edit, 0x100, 0xD, 0)  # Enter commits.
                wait_closed(popup)
                assert preference.read_text().strip() == value
                popup, edit = open_settings()
                assert text(edit) == value
                N.send_msg(popup, 0x111, 2)

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
            N.send_msg(popup, 0x111, 2)

            # A failed write leaves the editor open and the existing value active.
            saved = preference.read_bytes()
            preference.unlink()
            preference.mkdir()
            try:
                popup, edit = open_settings()
                set_text(edit, "2")
                N.post_msg(N.dlg_item(popup, 1), 0xF5, 0, 0)
                warning = wait_for(process.pid, "#32770")
                N.send_msg(warning, 0x111, 1)
                assert u.IsWindow(popup)
                N.send_msg(popup, 0x111, 2)
                popup, edit = open_settings()
                assert text(edit) == "500"
                N.send_msg(popup, 0x111, 2)
            finally:
                preference.rmdir()
                preference.write_bytes(saved)
        finally:
            N.stop_app(process, hwnd)

    preference.write_text("invalid")
    process, hwnd = N.launch_app(exe, db, settle=0)
    try:
        N.send_msg(hwnd, 0x111, 1003)
        popup = wait_for(process.pid, "aika_settings")
        assert N.get_text(N.dlg_item(popup, 101)) == "1"
        N.send_msg(popup, 0x111, 2)
    finally:
        N.stop_app(process, hwnd)
print("PASS: settings validation, save/cancel/close, restart persistence, light/dark, tracking while open")
