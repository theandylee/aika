"""PID-scoped resource soak, including paints inside a native menu's modal loop.

python tools/test-resources-ui.py build/aika-step6.exe [paint-count=2000]
Uses only a synthetic temporary DB. Prints measurements, checks bounded growth
after warm-up, exercises popup/resize/cancellation and hidden Day controls.
"""
import ctypes as c
from ctypes import wintypes as w
from contextlib import closing
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from native_ui import find_window, windows_for

u = c.WinDLL("user32", use_last_error=True)
k = c.WinDLL("kernel32", use_last_error=True)
ps = c.WinDLL("psapi", use_last_error=True)
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.InvalidateRect.argtypes = [w.HWND, c.c_void_p, w.BOOL]
u.UpdateWindow.argtypes = [w.HWND]
u.GetGuiResources.argtypes = [w.HANDLE, w.DWORD]
u.GetGuiResources.restype = w.DWORD
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.GetClientRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
u.MoveWindow.argtypes = [w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.BOOL]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.SetForegroundWindow.argtypes = [w.HWND]
u.IsWindowVisible.argtypes = [w.HWND]
k.GetProcessHandleCount.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]


class Memory(c.Structure):
    _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [
        (name, c.c_size_t) for name in ["peak_working", "working", "peak_paged", "paged",
                                      "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile", "private"]]


ps.GetProcessMemoryInfo.argtypes = [w.HANDLE, c.POINTER(Memory), w.DWORD]


def sample(process):
    handle = w.HANDLE(process._handle)
    memory = Memory(cb=c.sizeof(Memory))
    assert ps.GetProcessMemoryInfo(handle, c.byref(memory), memory.cb)
    handles = w.DWORD()
    assert k.GetProcessHandleCount(handle, c.byref(handles))
    return dict(private=memory.private, working=memory.working, handles=handles.value,
                gdi=u.GetGuiResources(handle, 0), user=u.GetGuiResources(handle, 1))


def send(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def click(hwnd, x, y):
    point = (y << 16) | x
    send(hwnd, 0x201, 1, point)
    send(hwnd, 0x202, 0, point)


exe = str(Path(sys.argv[1]).resolve())
paints = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode"
with tempfile.TemporaryDirectory(prefix="aika-soak-", dir=root) as folder:
    db = Path(folder) / "synthetic.db"
    source = (Path(__file__).resolve().parents[1] / "src/db.odin").read_text()
    midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    date = (midnight - datetime(2000, 1, 1)).days
    start = int(midnight.timestamp() * 1000)
    with closing(sqlite3.connect(db)) as conn:
        conn.executescript(re.search(r'SCHEMA_SQL :: `(.*?)`', source, re.S)[1])
        conn.executescript(re.search(r'SEED_SQL :: `(.*?)`', source, re.S)[1])
        conn.execute('INSERT INTO "Group"(GroupId,TimelineId,DisplayName,Key) VALUES(100,3,?,?)', ("Synthetic app", "soak-app"))
        conn.executemany("INSERT INTO Activity(TimelineId,DisplayName,GroupId,StartLocalDate,StartLocalTime,StartUtcTime,"
                         "EndLocalDate,EndLocalTime,EndUtcTime,StartUtcMs,EndUtcMs) VALUES(3,?,100,?,'','',?,'','',?,?)",
                         [(f"Synthetic window {i}", date, date, start + i * 96000, start + (i + 1) * 96000) for i in range(900)])
        conn.commit()
    process = subprocess.Popen([exe, "--db", str(db)])
    hwnd = None
    try:
        assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
        hwnd = find_window(process.pid, "aika_window_class")
        tray = find_window(process.pid, "aika_tray_window_class")
        assert hwnd and tray
        time.sleep(0.7)

        def paint():
            u.InvalidateRect(hwnd, None, False)
            u.UpdateWindow(hwnd)

        for _ in range(100):
            paint()
        # Exercise partial-size destruction/recreation and popup ownership first.
        for i in range(30):
            u.MoveWindow(hwnd, 100, 60, 1250 + (i % 2) * 100, 850, True)
            send(hwnd, 0x111, 1003)  # Settings
            popup = find_window(process.pid, "aika_settings")
            assert popup
            send(popup, 0x10)
            click(hwnd, 450, 50)
            popup = find_window(process.pid, "aika_tag_picker")
            assert popup
            send(popup, 0x10)
            paint()

        samples = [("warm", sample(process))]
        u.SetForegroundWindow(hwnd)
        u.PostMessageW(tray, 0x8001, 1, 0x205)
        deadline = time.monotonic() + 5
        while not find_window(process.pid, "#32768"):
            assert time.monotonic() < deadline, "Native menu did not open"
            time.sleep(0.01)
        begin = time.perf_counter()
        for i in range(paints):
            paint()
            if i % 20 == 0:
                send(hwnd, 0x113, 1)  # Timer while outer menu callback is suspended.
            if (i + 1) % max(1, paints // 4) == 0:
                assert find_window(process.pid, "#32768"), ("Menu must still own a nested native loop", i + 1, process.poll(), sample(process))
                samples.append((f"modal paint {i+1}", sample(process)))
        elapsed = time.perf_counter() - begin
        send(hwnd, 0x1F)  # Cancel menu.
        paint()
        samples.append(("after menu", sample(process)))
        print(json.dumps(dict(exe=exe, paints=paints, elapsed_seconds=round(elapsed, 3), samples=samples), indent=2))
        # High-water room for Windows/theme caches, not a claim of zero allocations.
        before = samples[0][1]
        peak = {key: max(value[key] for _, value in samples[1:-1]) for key in before}
        assert peak["private"] - before["private"] < 12 * 1024 * 1024, "Scratch grew during nested modal paints"
        assert peak["gdi"] - before["gdi"] <= 4 and peak["user"] - before["user"] <= 8
        # Windows may lazily start text/metadata services; distinguish their
        # one-time handle plateau from linear per-paint leakage.
        assert peak["handles"] - before["handles"] <= 32
        assert samples[-2][1]["handles"] - samples[-3][1]["handles"] <= 8

        # Hidden task/date/lane controls must not activate on placeholder tabs.
        click(hwnd, 150, 12)  # Timesheet tab.
        date_button = find_window(process.pid, "BUTTON", hwnd)
        assert date_button and not u.IsWindowVisible(date_button), "Day date button must be hidden"
        click(hwnd, 450, 50)
        assert not find_window(process.pid, "aika_tag_picker")
        click(hwnd, 35, 50)  # Hidden previous date.
        click(hwnd, 250, 120)  # Hidden lane.
        click(hwnd, 35, 12)  # Day tab.
        assert u.IsWindowVisible(date_button)
        send(hwnd, 0x111, 1002)
        assert process.wait(timeout=10) == 0
        print("PASS: bounded modal scratch/GDI/USER/handles, popup/resize cycles, hidden controls")
    finally:
        if process.poll() is None:
            if hwnd:
                send(hwnd, 0x1F)
                # If a hidden-control regression opened a picker, close only ours.
                for popup in windows_for(process.pid, "aika_tag_picker"):
                    send(popup, 0x10)
                send(hwnd, 0x111, 1002)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
