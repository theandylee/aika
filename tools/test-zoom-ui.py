"""Native zoom/pan interaction smoke test with an isolated database.

Run: python tools/test-zoom-ui.py build/aika.exe

Drives synthetic mouse/keyboard messages and reads the zoom overview's selection
back from the painted pixels (the orange edge handles), so it checks what the user
sees: overview drag (inside, outside, edges), wheel zoom, middle-button timeline
pan, Escape / WM_CANCELMODE / WM_CAPTURECHANGED rollback, wheel ignored mid-drag
and left press ignored mid-pan. Uses the pixel harness helpers; do not use the
mouse while it runs.
"""
import ctypes as c
from ctypes import wintypes as w
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here))
spec = importlib.util.spec_from_file_location("pixel_snapshot", here / "pixel-snapshot.py")
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)
u = ps.u

CW, CH = 1320, 860
ACCENT_BGR = (0x30, 0xA0, 0xF0)  # C_ACCENT, the same in both themes
MK_LBUTTON, MK_MBUTTON = 0x1, 0x10
WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0200, 0x0201, 0x0202
WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEWHEEL = 0x0207, 0x0208, 0x020A
WM_KEYDOWN, WM_CANCELMODE, WM_CAPTURECHANGED = 0x0100, 0x001F, 0x0215


class Scene:
    def __init__(self, hwnd):
        self.hwnd = hwnd
        self.geo = ps.Geo(CW, CH)
        g = self.geo
        self.bar_left = g.chart_x + 42
        self.bar_right = g.chart_x + g.chart_w - 148  # minus.left - 8
        self.handle_y = g.zoom_y + 4 + 3  # solid handle pixels, above the grip line
        self.bar_y = g.zoom_y + 4 + 13
        self.lane_y = g.lane_y + 10

    def selection(self):
        """(left, right) pixel extent of the overview selection, from its handles."""
        pix = ps.grab(self.hwnd, CW, CH)
        row = self.handle_y * CW * 4
        xs = [x for x in range(CW)
              if tuple(pix[row + x * 4:row + x * 4 + 3]) == ACCENT_BGR]
        assert xs, "no zoom handles found"
        return min(xs), max(xs) + 1

    def send(self, msg, wp, x, y):
        result = u.SendMessageW(self.hwnd, msg, wp, ps.point(x, y))
        if msg in (WM_LBUTTONDOWN, WM_MBUTTONDOWN):
            # SetCapture makes the OS post a MOUSEMOVE at the real cursor position;
            # let it drain so it cannot land after the synthetic drag moves.
            time.sleep(0.15)
        return result

    def wheel(self, x, y, notches):
        pt = w.POINT(x, y)
        u.ClientToScreen(self.hwnd, c.byref(pt))
        delta = (notches * 120) & 0xFFFF
        return u.SendMessageW(self.hwnd, WM_MOUSEWHEEL, delta << 16, ps.point(pt.x, pt.y))

    def park(self, x, y):
        """Park the real cursor: captured drags also receive OS-generated moves at its position."""
        pt = w.POINT(x, y)
        u.ClientToScreen(self.hwnd, c.byref(pt))
        u.SetCursorPos(pt.x, pt.y)
        time.sleep(0.05)

    def drag(self, down, wp, x0, y0, x1, y1):
        """Press at (x0,y0) and move to (x1,y1) with the cursor already parked there."""
        self.park(x1, y1)
        self.send(down, wp, x0, y0)
        self.send(WM_MOUSEMOVE, wp, x1, y1)
        self.settle()

    def key(self, vk):
        u.SendMessageW(self.hwnd, WM_KEYDOWN, vk, 0)

    def settle(self):
        time.sleep(0.12)
        u.UpdateWindow(self.hwnd)


def near(a, b, tol=3):
    return abs(a - b) <= tol


def main(exe):
    exe = str(Path(exe).resolve())
    root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aika-zoom-", dir=root) as folder:
        process, hwnd = ps.launch(exe, Path(folder) / "test.db")
        try:
            run(hwnd)
        finally:
            ps.stop(process, hwnd)


def run(hwnd):
    ps.set_client_size(hwnd, CW, CH)
    s = Scene(hwnd)
    mid_lane = s.geo.chart_x + s.geo.chart_w // 2
    L, M = (WM_LBUTTONDOWN, MK_LBUTTON), (WM_MBUTTONDOWN, MK_MBUTTON)

    full = s.selection()
    assert near(full[0], s.bar_left) and near(full[1], s.bar_right), (full, s.bar_left, s.bar_right)

    # Wheel over the lanes zooms; over the details list it must not.
    s.park(mid_lane, s.lane_y)
    for _ in range(3):
        s.wheel(mid_lane, s.lane_y, 1)
    s.settle()
    zoomed = s.selection()
    assert (zoomed[1] - zoomed[0]) < (full[1] - full[0]) * 0.6, (full, zoomed)
    s.wheel(mid_lane, s.geo.list_top + 40, 2)
    s.settle()
    assert s.selection() == zoomed, "Wheel over the list changed the zoom"

    # Overview drag inside the selection: moves, span is kept; Escape restores.
    inside = (zoomed[0] + zoomed[1]) // 2
    s.drag(*L, inside, s.bar_y, inside - 60, s.bar_y)
    dragged = s.selection()
    assert near(dragged[0], zoomed[0] - 60) and near(dragged[1] - dragged[0], zoomed[1] - zoomed[0]), (zoomed, dragged)
    s.wheel(mid_lane, s.lane_y, -1)  # ignored while a drag is live
    s.settle()
    assert s.selection() == dragged, "Wheel changed the zoom during an overview drag"
    s.key(0x1B)
    s.send(WM_LBUTTONUP, 0, inside - 60, s.bar_y)
    s.settle()
    assert s.selection() == zoomed, ("Escape did not restore the overview drag", zoomed, s.selection())

    # Capture loss and cancel-mode roll back as well; a later release is harmless.
    # (A synthetic WM_CAPTURECHANGED does not drop the real capture, so end it
    # with a release-and-cancel before the next drag.)
    for message in (WM_CAPTURECHANGED, WM_CANCELMODE):
        s.drag(*L, inside, s.bar_y, inside + 80, s.bar_y)
        assert s.selection() != zoomed, (hex(message), "drag did not start")
        u.SendMessageW(hwnd, message, 0, 0)
        s.settle()
        assert s.selection() == zoomed, (hex(message), "did not restore", zoomed, s.selection())
        s.key(0x1B)  # releases a capture a synthetic message left behind
        s.send(WM_LBUTTONUP, 0, inside + 80, s.bar_y)
        s.settle()
        assert s.selection() == zoomed, (hex(message), "late release changed the view", s.selection())

    # A normal release commits and Escape afterwards is a no-op.
    s.drag(*L, inside, s.bar_y, inside + 50, s.bar_y)
    s.send(WM_LBUTTONUP, 0, inside + 50, s.bar_y)
    s.settle()
    moved = s.selection()
    assert near(moved[0], zoomed[0] + 50) and near(moved[1] - moved[0], zoomed[1] - zoomed[0]), (zoomed, moved)
    s.key(0x1B)
    s.settle()
    assert s.selection() == moved, "Escape rolled back a finished drag"

    # Outside click recentres on the pointer.
    target = min(s.bar_right - 20, moved[1] + 120)
    s.park(target, s.bar_y)
    s.send(*L, target, s.bar_y)
    s.send(WM_LBUTTONUP, 0, target, s.bar_y)
    s.settle()
    centred = s.selection()
    assert near((centred[0] + centred[1]) // 2, target, 4) or centred[1] >= s.bar_right - 4, (target, centred)

    # Edge handle: resizes only that side.
    left_x = centred[0] + 2
    s.drag(*L, left_x, s.bar_y, left_x - 40, s.bar_y)
    s.send(WM_LBUTTONUP, 0, left_x - 40, s.bar_y)
    s.settle()
    widened = s.selection()
    assert near(widened[0], centred[0] - 40, 4) and near(widened[1], centred[1]), (centred, widened)

    # Middle-button pan on the lanes: content follows the pointer.
    before = s.selection()
    s.drag(*M, mid_lane, s.lane_y, mid_lane + 150, s.lane_y)
    panned = s.selection()
    assert panned[0] < before[0] and near(panned[1] - panned[0], before[1] - before[0], 2), (before, panned)
    # A left press during the pan is ignored (it would recentre the overview).
    far = s.bar_right - 10
    s.send(WM_LBUTTONDOWN, MK_LBUTTON | MK_MBUTTON, far, s.bar_y)
    s.send(WM_LBUTTONUP, MK_MBUTTON, far, s.bar_y)
    s.settle()
    assert s.selection() == panned, "A left press changed the view during a pan"
    s.key(0x1B)
    s.send(WM_MBUTTONUP, 0, mid_lane + 150, s.lane_y)
    s.settle()
    assert s.selection() == before, ("Escape did not restore the pan", before, s.selection())

    s.drag(*M, mid_lane, s.lane_y, mid_lane + 150, s.lane_y)
    s.send(WM_MBUTTONUP, 0, mid_lane + 150, s.lane_y)
    s.settle()
    assert s.selection() == panned, ("Middle release did not commit the pan", panned, s.selection())

    # Cancel-mode during a pan restores too.
    s.drag(*M, mid_lane, s.lane_y, mid_lane - 200, s.lane_y)
    u.SendMessageW(hwnd, WM_CANCELMODE, 0, 0)
    s.send(WM_MBUTTONUP, 0, mid_lane - 200, s.lane_y)
    s.settle()
    assert s.selection() == panned, "Cancel mode did not restore the pan"
    print("PASS: wheel zoom, overview drag/edges/recentre, Escape/cancel rollback, middle pan, wheel/left-press gating")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/aika.exe")
