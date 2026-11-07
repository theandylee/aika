"""Check lock responsiveness, visible save errors, and cancelled Exit in isolation.

Run: python tools/test-persistence-ui.py build/aika.exe
"""
from contextlib import closing
import sqlite3
import time
import native_ui as N

exe = N.exe_from_argv("build/aika.exe")
with N.isolated_temp_dir("aika-persistence-") as folder:
    db = folder / "test.db"
    process, hwnd = N.launch_app(exe, db)
    try:
        # Hold the SQLite writer lock, without blocking WAL readers. No real
        # foreground/idle input is injected; the usage endpoint eventually writes
        # whether the user's session is Active or Away.
        with closing(sqlite3.connect(db, timeout=1)) as blocker:
            blocker.execute("BEGIN IMMEDIATE")
            N.wait_for(lambda: "Tracking save error" in N.window_title(hwnd), 15, "save-error state")
            for _ in range(3):
                N.responsive_tick(hwnd)
                time.sleep(0.55)
            # Post, rather than synchronously send: cancelled Exit presents a
            # native message box. Locate it strictly within this process.
            N.post_msg(hwnd, 0x0111, 1002, 0)
            popup = N.wait_for(lambda: N.find_window(process.pid, "#32770"), 15, "Exit-cancelled dialog")
            assert process.poll() is None, "Exit must not discard pending writes"
            assert "Exit cancelled" in N.window_title(N.dlg_item(popup, 65535)), N.window_title(popup)
            N.post_msg(popup, 0x0010, 0, 0)  # Dismiss the acknowledgement box.
            N.wait_for(lambda: N.find_window(process.pid, "#32770") is None, 15, "error dialog dismissal")
            assert "Tracking save error" in N.window_title(hwnd)
            blocker.rollback()
        N.wait_for(lambda: N.window_title(hwnd) == "aika", 15, "error recovery")
        N.responsive_tick(hwnd)
        with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
            count = conn.execute("SELECT count(*) FROM Activity WHERE TimelineId=2").fetchone()[0]
            assert count >= 2, "Both finalized and resumed usage must survive recovery"
            assert conn.execute(
                "SELECT count(*) FROM Activity WHERE TimelineId=2 AND EndUtcMs < StartUtcMs"
            ).fetchone()[0] == 0
        N.post_msg(hwnd, 0x0111, 1002, 0)
        process.wait(timeout=10)
        assert process.returncode == 0
        print("PASS: lock responsiveness, visible error, cancelled Exit, retry recovery, clean Exit")
    finally:
        popup = N.find_window(process.pid, "#32770")
        if popup:
            N.post_msg(popup, 0x0010, 0, 0)
        N.ensure_closed(process, hwnd)
