"""Render assets/aika.svg into assets/aika.ico (PNG-compressed, multi-size).

Needs PyMuPDF (pip install pymupdf). Run from the repo root:
    python tools/make-icon.py
"""
import struct
from pathlib import Path

import fitz  # PyMuPDF

ROOT = Path(__file__).resolve().parent.parent
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]

doc = fitz.open(ROOT / "assets" / "aika.svg")
page = doc[0]

# Trim the transparent margin: find the opaque bounding box at full size, then render
# only that (squared, centred) region so the artwork fills the icon.
full = page.get_pixmap(alpha=True)
w, h, n = full.width, full.height, full.n
a = full.samples[n - 1::n]  # alpha channel
xs = [x for x in range(w) if any(a[y * w + x] > 8 for y in range(0, h, 2))]
ys = [y for y in range(h) if any(a[y * w + x] > 8 for x in range(0, w, 2))]
x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
side = max(x1 - x0, y1 - y0)
cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
clip = fitz.Rect(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
print("opaque bbox", x0, y0, x1, y1, "of", w, h)

pngs = []
for s in SIZES:
    z = s / side
    pix = page.get_pixmap(matrix=fitz.Matrix(z, z), clip=clip, alpha=True)
    pngs.append(pix.tobytes("png"))

out = bytearray(struct.pack("<HHH", 0, 1, len(SIZES)))
offset = 6 + 16 * len(SIZES)
for s, data in zip(SIZES, pngs):
    out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
for data in pngs:
    out += data
(ROOT / "assets" / "aika.ico").write_bytes(out)
print("wrote assets/aika.ico", len(out), "bytes")
