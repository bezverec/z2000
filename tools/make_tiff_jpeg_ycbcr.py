"""Wrap libjpeg-encoded chunks (via ImageMagick) into a TIFF with
Compression 7, Photometric YCbCr, and shared JPEGTables.

usage: make_tiff_jpeg_ycbcr.py SRC.png OUT.tif --sampling 2x2 [--tile 64x64 | --rows 32]
       [--refbw] [--keep-tables] [--quality 90]
Also writes OUT.chunks.raw: RGB assembled from ImageMagick's decode of each
chunk JPEG (libjpeg), cropped to the image, as a second oracle.
"""
import argparse, struct, subprocess, os, tempfile

ap = argparse.ArgumentParser()
ap.add_argument('src'); ap.add_argument('out')
ap.add_argument('--sampling', default='2x2')
ap.add_argument('--tile'); ap.add_argument('--rows', type=int)
ap.add_argument('--refbw', action='store_true')
ap.add_argument('--keep-tables', action='store_true')
ap.add_argument('--quality', type=int, default=90)
ap.add_argument('--restart', type=int, default=0)
a = ap.parse_args()

w, h = map(int, subprocess.run(['magick', 'identify', '-format', '%w %h', a.src], capture_output=True, check=True, text=True).stdout.split())
if a.tile:
    cw, ch = map(int, a.tile.split('x')); padded = True
else:
    cw, ch = w, (a.rows or h); padded = False
across = (w + cw - 1) // cw; down = (h + ch - 1) // ch

def segments(jpg):
    """Split into (marker, bytes) up to SOS; the rest is scan data + EOI."""
    out = []; p = 2
    assert jpg[:2] == b'\xff\xd8'
    while True:
        assert jpg[p] == 0xff
        m = jpg[p + 1]
        if m == 0xda:
            out.append((m, jpg[p:])); return out
        ln = struct.unpack('>H', jpg[p + 2:p + 4])[0]
        out.append((m, jpg[p:p + 2 + ln])); p += 2 + ln

tmp = tempfile.mkdtemp()
chunks = []; tables = None; oracle = bytearray(w * h * 3)
for cy in range(down):
    for cx in range(across):
        x0, y0 = cx * cw, cy * ch
        rows = ch if padded else min(ch, h - y0)
        cols = cw if padded else w
        jp = os.path.join(tmp, 'c.jpg')
        cmd = ['magick', a.src, '-depth', '8', '-crop', f'{min(cw, w - x0)}x{min(rows, h - y0)}+{x0}+{y0}', '+repage',
               '-background', 'gray', '-gravity', 'NorthWest', '-extent', f'{cols}x{rows}',
               '-sampling-factor', a.sampling, '-quality', str(a.quality), '-define', 'jpeg:optimize-coding=false']
        if a.restart: cmd += ['-define', f'jpeg:restart-interval={a.restart}']
        subprocess.run(cmd + ['-strip', jp], check=True)
        jpg = open(jp, 'rb').read()
        segs = segments(jpg)
        tbl = b''.join(s for m, s in segs if m in (0xdb, 0xc4))
        if tables is None: tables = tbl
        assert tbl == tables, 'chunks disagree on tables'
        keep = [s for m, s in segs if a.keep_tables or m not in (0xdb, 0xc4)]
        chunks.append(b'\xff\xd8' + b''.join(keep))
        dec = subprocess.run(['magick', jp, '-depth', '8', 'rgb:-'], capture_output=True, check=True).stdout
        for r in range(min(rows, h - y0)):
            for c in range(min(cw, w - x0)):
                t = ((y0 + r) * w + x0 + c) * 3; q = (r * cols + c) * 3
                oracle[t:t + 3] = dec[q:q + 3]
jpeg_tables = b'\xff\xd8' + tables + b'\xff\xd9'

sub = tuple(int(v) for v in a.sampling.split('x'))
entries = []  # (tag, type, count, data bytes)
def short(tag, *vals): entries.append((tag, 3, len(vals), struct.pack('<%dH' % len(vals), *vals)))
def long_(tag, *vals): entries.append((tag, 4, len(vals), struct.pack('<%dI' % len(vals), *vals)))
short(256, w); short(257, h); short(258, 8, 8, 8); short(259, 7); short(262, 6)
short(277, 3); short(284, 1)
if padded: short(322, cw); short(323, ch)
else: short(278, ch)
entries.append((347, 7, len(jpeg_tables), jpeg_tables))
short(530, *sub)
if a.refbw:
    entries.append((532, 5, 6, struct.pack('<12I', 0, 1, 255, 1, 128, 1, 255, 1, 128, 1, 255, 1)))
# offsets/counts placeholders, filled after layout
off_tag, cnt_tag = (324, 325) if padded else (273, 279)
long_(off_tag, *([0] * len(chunks))); long_(cnt_tag, *[len(c) for c in chunks])
entries.sort(key=lambda e: e[0])

n = len(entries)
ifd_size = 2 + 12 * n + 4
data_start = 8 + ifd_size
blob = bytearray(); ext_offsets = {}
for tag, ty, cnt, data in entries:
    if len(data) > 4:
        ext_offsets[tag] = data_start + len(blob); blob += data
        if len(blob) % 2: blob += b'\0'
chunk_start = data_start + len(blob); pos = chunk_start; offs = []
for c in chunks:
    offs.append(pos); pos += len(c)
entries = [(t, ty, cnt, struct.pack('<%dI' % cnt, *offs) if t == off_tag else d) for t, ty, cnt, d in entries]
out = bytearray(b'II*\0' + struct.pack('<I', 8) + struct.pack('<H', n))
for tag, ty, cnt, data in entries:
    if len(data) > 4:
        val = struct.pack('<I', ext_offsets[tag])
    else:
        val = data.ljust(4, b'\0')
    out += struct.pack('<HHI', tag, ty, cnt) + val
out += struct.pack('<I', 0)
# re-emit blob with the real offsets array
blob = bytearray()
for tag, ty, cnt, data in entries:
    if len(data) > 4:
        assert ext_offsets[tag] == data_start + len(blob); blob += data
        if len(blob) % 2: blob += b'\0'
out += blob
assert len(out) == chunk_start
for c in chunks: out += c
open(a.out, 'wb').write(out)
open(a.out[:-4] + '.chunks.raw', 'wb').write(oracle)
print(a.out, len(out), 'chunks', len(chunks), 'tables', len(jpeg_tables))
