#!/usr/bin/env python3
# Makes the face mask textures, media/textures/WhispMask/<skin>.png: each
# vanilla skin's face, stretched and sagging like skin pulled off one skull
# and over another, and mutilated: dead pallor (human skins), hollow eyes,
# cuts, blood, a raw darkened edge and crude stitches where it was sewn.
# Only the face region is used by the mask model (tools/mask.py); the rest
# of each 256x256 texture is flat so the files stay small.
#   python3 tools/mask_textures.py "$G/textures/Body/" [preview dir]
import math, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import png

src_dir = sys.argv[1]
preview = sys.argv[2] if len(sys.argv) > 2 else None
here = os.path.dirname(os.path.abspath(__file__))
out_dir = os.path.join(here, '..', 'Contents/mods/TheWhisperers/42/media/textures/WhispMask')
os.makedirs(out_dir, exist_ok=True)

# The same list, in the same order, as S.MaskSkins in Whisperers_Stake.lua.
human = {'male': ['MaleBody0%d%s' % (i, s) for i in range(1, 6) for s in ('', 'a')],
         'female': ['FemaleBody0%d' % i for i in range(1, 6)]}
zombie = {}
for g, p in (('male', 'M'), ('female', 'F')):
    zombie[g] = []
    for i in range(1, 5):
        zombie[g].append('%s_ZedBody0%d' % (p, i))
        zombie[g] += ['%s_ZedBody0%d_level%d' % (p, i, l) for l in range(1, 4)]

CX, CY = 128.0, 39.0            # face centre in the 256px skin layout
RX, RY = 17.5, 18.0             # the mask model's UV extent (brow to chin)
EYES = ((121.0, 32.0), (135.0, 32.0))
KEEP = (96, 8, 160, 72)         # texture area kept; the rest is flat


def sample(px, x, y):
    """Bilinear sample, clamped."""
    x = min(max(x, 0.0), 254.999); y = min(max(y, 0.0), 254.999)
    x0, y0 = int(x), int(y); fx, fy = x - x0, y - y0
    out = []
    for k in range(4):
        a = px[y0][x0][k] * (1 - fx) + px[y0][x0 + 1][k] * fx
        b = px[y0 + 1][x0][k] * (1 - fx) + px[y0 + 1][x0 + 1][k] * fx
        out.append(a * (1 - fy) + b * fy)
    return out


def mix(c, d, a):
    return [c[k] * (1 - a) + d[k] * a for k in range(3)] + [c[3]]


def process(name, is_human):
    w, h, px = png.read(os.path.join(src_dir, name + '.png'))
    rnd = random.Random(name)            # the same wounds every build
    phase = rnd.uniform(0, 6.28)
    out = [[list(p) for p in row] for row in px]
    # Stretched and sagging: sample closer to the centre (features grow) and
    # from higher up (everything droops), with a slight sideways ripple.
    for y in range(KEEP[1], KEEP[3]):
        for x in range(KEEP[0], KEEP[2]):
            d = math.hypot((x - CX) / (RX + 6), (y - CY) / (RY + 6))
            s = max(0.0, 1.0 - d * d)
            side = abs(x - CX) / RX
            sx = CX + (x - CX) * (1 - 0.18 * s) + 1.4 * s * math.sin((y - CY) / 5.0)
            sy = CY + (y - CY) * (1 - 0.22 * s) - (2.2 + 3.0 * side * side) * s   # the sides sag most
            out[y][x] = sample(px, sx, sy)
    for y in range(KEEP[1], KEEP[3]):
        for x in range(KEEP[0], KEEP[2]):
            c = out[y][x]
            dn = math.hypot((x - CX) / RX, (y - CY) / RY)
            lum = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
            if is_human:                                         # dead: grey, waxy
                c = mix(c, [lum * 0.70, lum * 0.72, lum * 0.66], 0.6)
            # Mottled bruising (low-frequency, per skin).
            m = (math.sin(x * 0.45 + phase) + math.sin(y * 0.38 + phase * 1.7) + math.sin((x + y) * 0.21)) / 3
            if m > 0.25:
                c = mix(c, [85, 55, 70], 0.35 * (m - 0.25) / 0.75)
            if math.hypot((x - CX) / 5.0, (y - 48.5) / 1.1) < 1:   # mouth slit
                c = mix(c, [40, 12, 12], 0.45)
            for ex, ey in EYES:                                  # hollow eyes
                e = math.hypot((x - ex) / 4.5, (y - ey) / 3.2)
                if e < 1.0:
                    c = mix(c, [45, 18, 16], 0.55 * (1 - e))
            if dn > 0.78:                                        # raw, darkened edge
                c = mix(c, [70, 22, 18], min(0.75, (dn - 0.78) * 3.0))
            out[y][x] = c
    # Cuts: a few thin dark wounds with a lighter lip.
    for _ in range(rnd.randint(2, 4)):
        a = rnd.uniform(0, math.pi)
        r = rnd.uniform(0.2, 0.7)
        x0 = CX + math.cos(a * 2) * RX * r; y0 = CY + math.sin(a * 2) * RY * r
        ln = rnd.uniform(6, 13); ang = rnd.uniform(0, math.pi)
        for i in range(int(ln * 3)):
            t = i / (ln * 3)
            x = int(round(x0 + math.cos(ang) * ln * (t - 0.5)))
            y = int(round(y0 + math.sin(ang) * ln * (t - 0.5) + math.sin(t * 6) * 0.6))
            if KEEP[0] <= x < KEEP[2] and KEEP[1] <= y + 1 < KEEP[3]:
                out[y][x] = mix(out[y][x], [95, 8, 8], 0.9)
                out[y + 1][x] = mix(out[y + 1][x], [160, 60, 55], 0.35)
    # Blood: soft smears, mostly low on the face and dripping from the cuts.
    for _ in range(rnd.randint(3, 6)):
        bx = CX + rnd.uniform(-RX, RX) * 0.8; by = CY + rnd.uniform(-0.2, 1.0) * RY * 0.9
        br = rnd.uniform(2.0, 4.5)
        for y in range(int(by - br * 2), int(by + br * 2)):
            for x in range(int(bx - br), int(bx + br)):
                if KEEP[0] <= x < KEEP[2] and KEEP[1] <= y < KEEP[3]:
                    e = math.hypot((x - bx) / br, (y - by) / (br * 1.8))
                    if e < 1.0:
                        out[y][x] = mix(out[y][x], [110, 12, 10], 0.6 * (1 - e))
    # Stitches: crude, uneven cross-stitches near the edge, where it was sewn,
    # with gaps where the thread gave out.
    a = rnd.uniform(0, 1)
    while a < 2 * math.pi:
        r = rnd.uniform(0.82, 0.93)
        x = CX + math.cos(a) * RX * r; y = CY + math.sin(a) * RY * r
        ang = a + rnd.uniform(-0.6, 0.6)
        for t in (-0.9, 0.0, 0.9):
            sx = int(round(x + math.cos(ang) * t)); sy = int(round(y + math.sin(ang) * t))
            if KEEP[0] <= sx < KEEP[2] and KEEP[1] <= sy < KEEP[3]:
                out[sy][sx] = mix(out[sy][sx], [30, 20, 16], 0.9)
        a += rnd.uniform(0.28, 0.5) + (0.9 if rnd.random() < 0.12 else 0)
    # Flat outside the face: the mask never shows it, and it compresses.
    flat = out[int(CY)][int(CX)]
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            inside = KEEP[0] <= x < KEEP[2] and KEEP[1] <= y < KEEP[3]
            c = out[y][x] if inside else flat
            row.append(tuple(int(max(0, min(255, round(v)))) for v in c[:3]) + (255,))
        rows.append(row)
    png.write(os.path.join(out_dir, name + '.png'), w, h, rows)
    if preview:
        crop = [r[KEEP[0]:KEEP[2]] for r in rows[KEEP[1]:KEEP[3]]]
        big = [[c for c in row for _ in range(6)] for row in crop for _ in range(6)]
        png.write(os.path.join(preview, 'mask_' + name + '.png'), len(big[0]), len(big), big)


names = sys.argv[3:] if len(sys.argv) > 3 else None
for kind, table in (('zombie', zombie), ('human', human)):
    for g in ('male', 'female'):
        for skin in table[g]:
            if names and skin not in names:
                continue
            process(skin, kind == 'human')
print('wrote mask textures to', os.path.normpath(out_dir))
