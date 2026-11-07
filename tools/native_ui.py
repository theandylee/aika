"""Shared harness for isolated native UI tests (audit #25).

Every script drives its own aika process on a temporary database and must
scope all window discovery to that process ID: another aika instance may be
running on the same desktop, so desktop-global FindWindow/popups are banned.
This module owns the duplicated boilerplate the scripts grew independently:

- PID-scoped discovery: window_pid, windows_for, find_window
- process control: launch_app, stop_app, ensure_closed
- messaging: send_msg, point, click_at, dlg_item, post_msg
- waiting: wait_for (+ responsive_tick for lock-responsiveness checks)
- isolation: isolated_temp_dir, exe_from_argv, window_title

Only a synthetic temp DB is ever used; no running aika instance is touched.
"""

import ctypes as c
from contextlib import contextmanager
from ctypes import wintypes as w
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

u = c.WinDLL("user32", use_last_error=True)
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.EnumChildWindows.argtypes = [w.HWND, callback, w.LPARAM]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.SendMessageW.restype = c.c_ssize_t
u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
u.WaitForInputIdle.argtypes = [w.HANDLE, w.DWORD]
u.UpdateWindow.argtypes = [w.HWND]
u.GetDlgItem.argtypes = [w.HWND, c.c_int]
u.GetDlgItem.restype = w.HWND
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.IsWindow.argtypes = [w.HWND]
u.IsWindowEnabled.argtypes = [w.HWND]
u.IsWindowVisible.argtypes = [w.HWND]
u.SendMessageTimeoutW.argtypes = [
    w.HWND, w.UINT, w.WPARAM, w.LPARAM, w.UINT, w.UINT, c.POINTER(c.c_size_t)
]
u.SendMessageTimeoutW.restype = c.c_size_t

WM_CLOSE = 0x0010
WM_COMMAND = 0x0111
WM_SETTEXT = 0x000C
WM_GETTEXT = 0x000D
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_MOUSEMOVE = 0x0200
CMD_TRAY_EXIT = 1002  # tray menu Exit: flushes tracking and quits


def window_pid(hwnd):
    pid = w.DWORD()
    u.GetWindowThreadProcessId(hwnd, c.byref(pid))
    return pid.value


def windows_for(pid, class_name, parent=None):
    assert pid > 0, "An explicit process ID is required"
    found = []

    @callback
    def visit(hwnd, _):
        name = c.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, name, len(name))
        if window_pid(hwnd) == pid and name.value.casefold() == class_name.casefold():
            found.append(hwnd)
        return True

    if parent is not None:
        assert window_pid(parent) == pid, "Parent belongs to another process"
        u.EnumChildWindows(parent, visit, 0)
    else:
        u.EnumWindows(visit, 0)
    return found


def find_window(pid, class_name, parent=None):
    found = windows_for(pid, class_name, parent)
    return found[0] if found else None


def exe_from_argv(default="build/aika.exe"):
    return str(Path(sys.argv[1] if len(sys.argv) > 1 else default).resolve())


@contextmanager
def isolated_temp_dir(prefix):
    root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=prefix, dir=root) as folder:
        yield Path(folder)


def wait_for(predicate, timeout=15, what="native UI state"):
    """Poll predicate until truthy; return its value or raise."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {what}")


def wait_closed(hwnd, timeout=5):
    wait_for(lambda: not u.IsWindow(hwnd), timeout, "window close")
    assert not u.IsWindow(hwnd)


def launch_app(exe, db, settle=0.6):
    """Start an isolated instance; return (process, main hwnd).

    WaitForInputIdle can return before the first complete paint/timer tick,
    so settle briefly like every script did independently before.
    """
    process = subprocess.Popen([str(exe), "--db", str(db)])
    assert u.WaitForInputIdle(w.HANDLE(process._handle), 10000) == 0
    found = windows_for(process.pid, "aika_window_class")
    assert len(found) == 1, found
    time.sleep(settle)
    return process, found[0]


def stop_app(process, hwnd, timeout=10):
    """Tray-Exit (flushes tracking) and require a clean exit code."""
    send_msg(hwnd, WM_COMMAND, CMD_TRAY_EXIT, 0)
    assert process.wait(timeout=timeout) == 0, process.returncode


def ensure_closed(process, hwnd=None, timeout=5):
    """Finally-block cleanup: ask a lingering process to exit, then kill."""
    if process.poll() is None:
        if hwnd is not None:
            try:
                post_msg(hwnd, WM_COMMAND, CMD_TRAY_EXIT, 0)
            except OSError:
                pass
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def send_msg(hwnd, msg, wp=0, lp=0):
    return u.SendMessageW(hwnd, msg, wp, lp)


def post_msg(hwnd, msg, wp=0, lp=0):
    u.PostMessageW(hwnd, msg, wp, lp)


def point(x, y):
    return ((y & 0xFFFF) << 16) | (x & 0xFFFF)


def click_at(hwnd, x, y):
    send_msg(hwnd, WM_LBUTTONDOWN, 1, point(x, y))
    send_msg(hwnd, WM_LBUTTONUP, 0, point(x, y))
    u.UpdateWindow(hwnd)


def set_text(hwnd, value):
    buf = c.create_unicode_buffer(value)
    send_msg(hwnd, WM_SETTEXT, 0, c.addressof(buf))


def get_text(hwnd, capacity=64):
    buf = c.create_unicode_buffer(capacity)
    send_msg(hwnd, WM_GETTEXT, capacity, c.addressof(buf))
    return buf.value


def window_title(hwnd, capacity=512):
    text = c.create_unicode_buffer(capacity)
    u.GetWindowTextW(hwnd, text, len(text))
    return text.value


def dlg_item(hwnd, control_id):
    return u.GetDlgItem(hwnd, control_id)


def main_window(pid):
    found = windows_for(pid, "aika_window_class")
    assert len(found) == 1, found
    return found[0]


def responsive_tick(hwnd, timeout_ms=1000):
    """Fail if the main thread blocks (e.g. on database contention)."""
    result = c.c_size_t()
    assert u.SendMessageTimeoutW(hwnd, 0x0113, 1, 0, 2, timeout_ms, c.byref(result)), (
        "The main thread blocked on database contention"
    )
