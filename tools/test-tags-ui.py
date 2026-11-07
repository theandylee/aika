"""Native mouse/keyboard smoke test; uses its own process and temporary database.

Run after building: python tools/test-tags-ui.py build/aika-tags.exe
"""
import ctypes as c
from contextlib import closing
import sqlite3
import native_ui as N

u = N.u


def drag(hwnd, x1, x2):
    N.send_msg(hwnd, 0x0201, 1, N.point(x1, 120))
    N.send_msg(hwnd, 0x0200, 1, N.point(x2, 120))
    N.send_msg(hwnd, 0x0202, 0, N.point(x2, 120))


def double_click(hwnd, x):
    drag(hwnd, x, x)  # First click
    N.send_msg(hwnd, 0x0203, 1, N.point(x, 120))  # WM_LBUTTONDBLCLK
    N.send_msg(hwnd, 0x0202, 0, N.point(x, 120))


exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-tags-") as folder:
    db = folder / "test.db"
    process, hwnd = N.launch_app(exe, db)
    try:
        def rows():
            with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
                return conn.execute("SELECT ActivityId, GroupId, StartUtcMs, EndUtcMs "
                                    "FROM Activity WHERE TimelineId=1 ORDER BY ActivityId").fetchall()

        def picker():
            popup = N.find_window(process.pid, "aika_tag_picker")
            assert popup, "Tag picker did not open"
            return popup

        drag(hwnd, 200, 400)
        popup = picker()
        N.set_text(N.dlg_item(popup, 101), "UI smoke tag")
        N.send_msg(popup, 0x0111, 104, N.dlg_item(popup, 104))
        first = rows()
        assert len(first) == 1 and first[0][3] > first[0][2], first

        # Reverse drag, search an existing tag, and select it.
        drag(hwnd, 800, 600)
        popup = picker()
        N.set_text(N.dlg_item(popup, 101), "smoke")
        assert N.send_msg(N.dlg_item(popup, 102), 0x018B) == 1  # LB_GETCOUNT
        N.send_msg(popup, 0x0111, 103, N.dlg_item(popup, 103))
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
        N.send_msg(picker(), 0x0010)  # WM_CLOSE
        assert rows() == after_right
        drag(hwnd, 950, 950)
        assert not N.find_window(process.pid, "aika_tag_picker")
        assert u.IsWindowEnabled(hwnd)

        # An interior drag must not even open the picker, in either direction.
        drag(hwnd, 250, 350)
        assert not N.find_window(process.pid, "aika_tag_picker")
        drag(hwnd, 350, 250)
        assert not N.find_window(process.pid, "aika_tag_picker")
        assert rows() == after_right

        def use_existing():
            popup = picker()
            N.send_msg(popup, 0x0111, 103, N.dlg_item(popup, 103))

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
        N.send_msg(picker(), 0x0010)
        assert rows() == extended, "Cancelling gap fill changed persisted blocks"
        double_click(hwnd, 400)
        use_existing()
        filled = rows()
        assert len(filled) == len(extended) + 1
        assert filled[-1][2] == extended[0][3] and filled[-1][3] == extended[2][2]
        assert filled[:-1] == extended
        extended = filled
        double_click(hwnd, 400)  # Now occupied
        assert not N.find_window(process.pid, "aika_tag_picker")
        double_click(hwnd, 50)  # No block on the left
        assert not N.find_window(process.pid, "aika_tag_picker")
        assert rows() == extended

        def menu_visible():
            menu = N.find_window(process.pid, "#32768")
            return menu is not None and N.window_pid(menu) == process.pid

        def open_menu():
            # DefWindowProc converts right-button release to WM_CONTEXTMENU.
            N.post_msg(hwnd, 0x0205, 0, N.point(250, 120))
            N.wait_for(menu_visible, 5, "native context menu")

        open_menu()
        N.post_msg(hwnd, 0x0100, 0x1B, 0)  # Escape cancels
        N.wait_for(lambda: not menu_visible(), 5, "menu dismissal")
        assert rows() == extended
        open_menu()
        N.post_msg(hwnd, 0x0100, 0x28, 0)  # Down selects Delete
        N.post_msg(hwnd, 0x0100, 0x0D, 0)  # Enter activates it
        N.wait_for(lambda: len(rows()) == len(extended) - 1, 5, "tag deletion")
        remaining = rows()
        assert remaining == extended[1:], "Delete changed an unrelated block"
        # The tag itself remains searchable and reusable after deletion.
        drag(hwnd, 250, 350)
        popup = picker()
        N.set_text(N.dlg_item(popup, 101), "smoke")
        assert N.send_msg(N.dlg_item(popup, 102), 0x018B) == 1
        # Storage contention is not an overlap: keep the picker and selection
        # alive, then retry successfully after releasing the independent writer.
        with closing(sqlite3.connect(db, timeout=1)) as blocker:
            blocker.execute("BEGIN IMMEDIATE")
            N.post_msg(popup, 0x0111, 103, N.dlg_item(popup, 103))
            dialog = N.wait_for(lambda: N.find_window(process.pid, "#32770"), 5, "save-error dialog")
            assert "Could not save tag" in N.window_title(N.dlg_item(dialog, 65535)), N.window_title(N.dlg_item(dialog, 65535))
            N.post_msg(dialog, 0x0010, 0, 0)
            N.wait_for(lambda: not N.find_window(process.pid, "#32770"), 5, "error dialog dismissal")
            assert picker() == popup, "A storage failure dismissed the tag picker"
            assert rows() == remaining, "Failed save changed tag history"
            blocker.rollback()
        use_existing()
        retried = rows()
        assert len(retried) == len(remaining) + 1 and retried[:-1] == remaining
        remaining = retried

        # Graceful exit flushes tracking and tags remain in the on-disk DB.
        N.stop_app(process, hwnd)  # Tray Exit (WM_CLOSE now hides).
        assert rows() == remaining
        print("PASS: tagging, non-overlap, resize, double-click gap fill, delete, tag reuse, storage retry, persistence")
    finally:
        for cls in ("#32770", "aika_tag_picker"):
            popup = N.find_window(process.pid, cls)
            if popup:
                N.post_msg(popup, 0x0010, 0, 0)
        N.ensure_closed(process, hwnd)
