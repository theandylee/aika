"""Task toolbar smoke test in an isolated process/database.

Run: python tools/test-task-ui.py build/aika-task.exe
"""
import ctypes as c
from contextlib import closing
import sqlite3
import time
import native_ui as N

exe = N.exe_from_argv("build/aika-task.exe")
with N.isolated_temp_dir("aika-task-") as folder:
    db = folder / "test.db"
    process, hwnd = N.launch_app(exe, db)
    try:
        def click_task():
            # Task button follows the 232px date picker (client x=388..520).
            N.send_msg(hwnd, 0x0201, 1, N.point(450, 50))
            N.send_msg(hwnd, 0x0202, 0, N.point(450, 50))

        def rows():
            with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
                return conn.execute("SELECT ActivityId, GroupId, StartUtcMs, EndUtcMs FROM Activity "
                                    "WHERE TimelineId=1 ORDER BY ActivityId").fetchall()

        click_task()
        popup = N.find_window(process.pid, "aika_tag_picker")
        assert popup
        N.send_msg(popup, 0x0010)
        assert rows() == [], "Cancel must not start a task"

        click_task()
        popup = N.find_window(process.pid, "aika_tag_picker")
        name = c.create_unicode_buffer("Task smoke")
        N.send_msg(N.dlg_item(popup, 101), 0x000C, 0, c.addressof(name))
        N.send_msg(popup, 0x0111, 104, N.dlg_item(popup, 104))
        first = rows()
        assert len(first) == 1
        time.sleep(2.5)
        growing = rows()
        assert growing[0][3] > first[0][3] + 1000
        click_task()
        stopped = rows()
        time.sleep(1.5)
        assert rows() == stopped, "Stopped block must not grow"

        click_task()
        popup = N.find_window(process.pid, "aika_tag_picker")
        N.send_msg(popup, 0x0111, 103, N.dlg_item(popup, 103))
        second = rows()
        assert len(second) == 2 and second[0][1] == second[1][1]
        N.send_msg(hwnd, 0x0010)  # Hide in tray, not exit.
        time.sleep(2.5)
        assert rows()[1][3] > second[1][3] + 1000
        N.send_msg(hwnd, 0x0111, 1002, 0)  # Tray Exit flushes the running task.
        process.wait(timeout=10)
        final = rows()
        assert final[0] == stopped[0] and final[1][3] >= second[1][3]
        print("PASS: picker cancel, create/reuse, live growth, stop, tray tracking, exit flush")
    finally:
        N.ensure_closed(process, hwnd)
