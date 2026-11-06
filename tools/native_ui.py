"""PID-scoped discovery for isolated native UI tests (including native menus).

Never use desktop-global FindWindow for popups: another aika instance may be
running. Child discovery also verifies PID, not just the class/parent handle.
"""
import ctypes as c
from ctypes import wintypes as w

u = c.WinDLL("user32", use_last_error=True)
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
u.EnumWindows.argtypes = [callback, w.LPARAM]
u.EnumChildWindows.argtypes = [w.HWND, callback, w.LPARAM]
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]


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
