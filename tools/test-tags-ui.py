"""Native mouse/keyboard smoke test; uses its own process and temporary database.

Run after building: python tools/test-tags-ui.py build/aika-tags.exe
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
u.FindWindowW.argtypes = [w.LPCWSTR, w.LPCWSTR]
u.FindWindowW.restype = w.HWND
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.EnumWindows.argtypes = [c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM), w.LPARAM]
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.IsWindowEnabled.argtypes = [w.HWND]
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def text(hwnd, value):
    buf = c.create_unicode_buffer(value)
    send(hwnd, 0x000C, 0, c.addressof(buf))


def drag(hwnd, x1, x2):
    send(hwnd, 0x0201, 1, (120 << 16) | x1)
    send(hwnd, 0x0200, 1, (120 << 16) | x2)
    send(hwnd, 0x0202, 0, (120 << 16) | x2)


def double_click(hwnd, x):
    drag(hwnd, x, x)  # First click
    send(hwnd, 0x0203, 1, (120 << 16) | x)  # WM_LBUTTONDBLCLK
    send(hwnd, 0x0202, 0, (120 << 16) | x)


def main_window(pid):
    found = []

    @c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    def visit(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        buf = c.create_unicode_buffer(256)
        u.GetClassNameW(w.HWND(hwnd), buf, 256)
        if owner.value == pid and buf.value == "aika_window_class":
            found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    assert len(found) == 1, found
    return found[0]


exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe").resolve())
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
with tempfile.TemporaryDirectory(prefix="aika-tags-", dir=root) as folder:
    db = Path(folder) / "test.db"
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
        hwnd = main_window(process.pid)

        def rows():
            with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
                return conn.execute("SELECT ActivityId, GroupId, StartUtcMs, EndUtcMs "
                                    "FROM Activity WHERE TimelineId=1 ORDER BY ActivityId").fetchall()

        def picker():
            popup = u.FindWindowW("aika_tag_picker", None)
            assert popup, "Tag picker did not open"
            return popup

        drag(hwnd, 200, 400)
        popup = picker()
        text(u.GetDlgItem(popup, 101), "UI smoke tag")
        send(popup, 0x0111, 104, u.GetDlgItem(popup, 104))
        first = rows()
        assert len(first) == 1 and first[0][3] > first[0][2], first

        # Reverse drag, search an existing tag, and select it.
        drag(hwnd, 800, 600)
        popup = picker()
        text(u.GetDlgItem(popup, 101), "smoke")
        assert send(u.GetDlgItem(popup, 102), 0x018B) == 1  # LB_GETCOUNT
        send(popup, 0x0111, 103, u.GetDlgItem(popup, 103))
        before = rows()
        assert len(before) == 2 and before[0][1] == before[1][1], before

        # Both borders resize independently and save on release.
        drag(hwnd, 600, 550)
        after_left = rows()
        assert after_left[1][2] < before[1][2] and after_left[1][3] == before[1][3]
        drag(hwnd, 800, 850)
        after_right = rows()
        assert after_right[1][2] == after_left[1][2] and after_right[1][3] > after_left[1][3]
        assert after_right[0] == first[0], "Unrelated tag was changed"

        # Cancelling and simple clicks must not insert a block.
        drag(hwnd, 950, 1050)
        send(picker(), 0x0010)  # WM_CLOSE
        assert rows() == after_right
        drag(hwnd, 950, 950)
        assert not u.FindWindowW("aika_tag_picker", None)
        assert u.IsWindowEnabled(hwnd)

        # An interior drag must not even open the picker, in either direction.
        drag(hwnd, 250, 350)
        assert not u.FindWindowW("aika_tag_picker", None)
        drag(hwnd, 350, 250)
        assert not u.FindWindowW("aika_tag_picker", None)
        assert rows() == after_right

        def use_existing():
            popup = picker()
            send(popup, 0x0111, 103, u.GetDlgItem(popup, 103))

        # Starting inside the first block creates only its free extension.
        drag(hwnd, 300, 500)
        use_existing()
        extended = rows()
        assert len(extended) == 3 and extended[2][2] == extended[0][3]
        drag(hwnd, 300, 100)
        use_existing()
        extended = rows()
        assert len(extended) == 4 and extended[3][3] == extended[0][2]

        # Resize toward an occupied block stops precisely at its edge.
        drag(hwnd, 550, 300)
        extended = rows()
        assert extended[1][2] == extended[2][3]
        ordered = sorted(extended, key=lambda row: row[2])
        assert all(a[3] <= b[2] for a, b in zip(ordered, ordered[1:])), ordered

        # Shared boundary: each handle is reachable from its own block's side.
        before_shared = extended
        drag(hwnd, 398, 370)
        extended = rows()
        assert extended[0][3] < before_shared[0][3], "Left block's right handle was not selected"
        assert extended[1:] == before_shared[1:], "Shared-edge drag changed the wrong block"
        drag(hwnd, 402, 430)
        after_shared = rows()
        assert after_shared[2][2] > extended[2][2], "Right block's left handle was not selected"
        assert after_shared[0] == extended[0] and after_shared[1] == extended[1]
        extended = after_shared

        # Double-click fills the whole bounded gap, using the regular picker.
        double_click(hwnd, 400)
        send(picker(), 0x0010)
        assert rows() == extended, "Cancelling gap fill changed persisted blocks"
        double_click(hwnd, 400)
        use_existing()
        filled = rows()
        assert len(filled) == len(extended) + 1
        assert filled[-1][2] == extended[0][3] and filled[-1][3] == extended[2][2]
        assert filled[:-1] == extended
        extended = filled
        double_click(hwnd, 400)  # Now occupied
        assert not u.FindWindowW("aika_tag_picker", None)
        double_click(hwnd, 50)  # No block on the left
        assert not u.FindWindowW("aika_tag_picker", None)
        assert rows() == extended

        def wait_for(predicate):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(0.01)
            raise AssertionError("Timed out waiting for native context menu")

        def menu_visible():
            menu = u.FindWindowW("#32768", None)
            owner = w.DWORD()
            if menu:
                u.GetWindowThreadProcessId(menu, c.byref(owner))
            return owner.value == process.pid

        def open_menu():
            # DefWindowProc converts right-button release to WM_CONTEXTMENU.
            u.PostMessageW(hwnd, 0x0205, 0, (120 << 16) | 250)
            wait_for(menu_visible)

        open_menu()
        u.PostMessageW(hwnd, 0x0100, 0x1B, 0)  # Escape cancels
        wait_for(lambda: not menu_visible())
        assert rows() == extended
        open_menu()
        u.PostMessageW(hwnd, 0x0100, 0x28, 0)  # Down selects Delete
        u.PostMessageW(hwnd, 0x0100, 0x0D, 0)  # Enter activates it
        wait_for(lambda: len(rows()) == len(extended) - 1)
        remaining = rows()
        assert remaining == extended[1:], "Delete changed an unrelated block"
        # The tag itself remains searchable and reusable after deletion.
        drag(hwnd, 250, 350)
        popup = picker()
        text(u.GetDlgItem(popup, 101), "smoke")
        assert send(u.GetDlgItem(popup, 102), 0x018B) == 1
        send(popup, 0x0010)

        # Graceful exit flushes tracking and tags remain in the on-disk DB.
        send(hwnd, 0x0010)
        process.wait(timeout=10)
        assert rows() == remaining
        print("PASS: tagging, non-overlap, resize, double-click gap fill, delete, tag reuse, persistence")
    finally:
        if process.poll() is None:
            popup = u.FindWindowW("aika_tag_picker", None)
            if popup:
                send(popup, 0x0010)
            if hwnd:
                send(hwnd, 0x0010)
            process.wait(timeout=10)
