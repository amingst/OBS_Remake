"""Regenerates streamsmith.png / streamsmith_256.png / streamsmith.ico.

    pip install pillow
    python assets/icons/generate.py

The icon is drawn procedurally on a 100x100 design grid, supersampled 3x and
downscaled. Colours come from src/ui/theme.odin. Concept: a cross-peen hammer
striking the anvil, and what flies off the impact is a broadcast signal.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S, N = 3, 1024              # supersample factor, output size
D = N * S
U = D / 100.0               # design-space unit

# theme.odin palette
SURFACE = (23, 31, 51)
TEXT = (218, 226, 253)
PRIMARY = (59, 130, 246)
AMBER = (245, 180, 40)


# ---------------------------------------------------------------- primitives
def new():
    return Image.new("RGBA", (D, D), (0, 0, 0, 0))


def mask():
    return Image.new("L", (D, D), 0)


def pts(p):
    return [(x * U, y * U) for x, y in p]


def fill(m, color):
    out = new()
    out.paste(Image.new("RGBA", (D, D), color + (255,)), (0, 0), m)
    return out


def round_mask(m, r):
    """Round every corner of a hard mask by blur + threshold."""
    return m.filter(ImageFilter.GaussianBlur(r * U)).point(lambda v: 255 if v >= 128 else 0)


def union(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = ImageChops.lighter(out, m)
    return out


def poly(p, r=0.0):
    m = mask()
    ImageDraw.Draw(m).polygon(pts(p), fill=255)
    return round_mask(m, r) if r else m


def rrect(x0, y0, x1, y1, r):
    m = mask()
    ImageDraw.Draw(m).rounded_rectangle([x0 * U, y0 * U, x1 * U, y1 * U], radius=r * U, fill=255)
    return m


def circle(cx, cy, r):
    m = mask()
    ImageDraw.Draw(m).ellipse([(cx - r) * U, (cy - r) * U, (cx + r) * U, (cy + r) * U], fill=255)
    return m


def stroke(p, w):
    m = mask()
    d = ImageDraw.Draw(m)
    pp = pts(p)
    d.line(pp, fill=255, width=int(w * U), joint="curve")
    for x, y in pp:  # round caps
        d.ellipse([x - w / 2 * U, y - w / 2 * U, x + w / 2 * U, y + w / 2 * U], fill=255)
    return m


def arc(cx, cy, r, a0, a1, w):
    """Stroked arc with round caps, as an annular-sector polygon (PIL's arc() is uneven)."""
    n = max(32, int((a1 - a0) / 1.5))
    ro, ri = r + w / 2, r - w / 2
    ang = lambda i: math.radians(a0 + (a1 - a0) * i / n)
    outer = [(cx + ro * math.cos(ang(i)), cy + ro * math.sin(ang(i))) for i in range(n + 1)]
    inner = [(cx + ri * math.cos(ang(i)), cy + ri * math.sin(ang(i))) for i in range(n, -1, -1)]
    m = mask()
    d = ImageDraw.Draw(m)
    d.polygon(pts(outer + inner), fill=255)
    for a in (a0, a1):
        x, y = cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))
        d.ellipse([(x - w / 2) * U, (y - w / 2) * U, (x + w / 2) * U, (y + w / 2) * U], fill=255)
    return m


def transform(p, scale, dx, dy):
    return [((x - 50) * scale + 50 + dx, (y - 50) * scale + 50 + dy) for x, y in p]


# ---------------------------------------------------------------- shapes
# Heel-less "T" anvil: face bar, horn, waist, base.
ANVIL = [(12, 32), (70, 32), (94, 38), (70, 44), (62, 44), (56, 68), (72, 68),
         (72, 80), (26, 80), (26, 68), (42, 68), (36, 44), (12, 44)]


def anvil(scale, dx, dy):
    return poly(transform(ANVIL, scale, dx, dy), r=1.2)


def hammer(x, yb, head_w=13, face_h=11, peen_h=8.5, handle_len=27, handle_w=6.2, angle=38):
    """Cross-peen hammer at the moment of impact: head vertical with its striking face on y=yb,
    peen tapering upward, handle leaving the head's left side at `angle` degrees above horizontal.
    Returns the mask and the head's bottom-right corner."""
    x0, x1 = x - head_w / 2, x + head_w / 2
    face = rrect(x0, yb - face_h, x1, yb, 1.8)
    peen = poly([(x0, yb - face_h + 1.5), (x1, yb - face_h + 1.5),
                 (x1 - 2.6, yb - face_h - peen_h), (x0 + 2.6, yb - face_h - peen_h)])
    ax, ay = x0 + 1.0, yb - face_h + 1.0
    a = math.radians(angle)
    handle = stroke([(ax, ay), (ax - handle_len * math.cos(a), ay - handle_len * math.sin(a))], handle_w)
    return round_mask(union(face, peen, handle), 0.7), (x1, yb)


# ---------------------------------------------------------------- composition
def render():
    badge = mask()
    ImageDraw.Draw(badge).rounded_rectangle([0, 0, D - 1, D - 1], radius=22 * U, fill=255)
    img = fill(badge, SURFACE)

    a_scale, a_dx, a_dy = 0.85, 2, 10.5
    face_top = (32 - 50) * a_scale + 50 + a_dy
    gap = 1.6                                   # hairline between hammer face and anvil

    h, (hx, _) = hammer(35.5, face_top - gap)
    ix, iy = hx + 2.2, face_top - 2.4           # spark = signal origin
    for r in (12, 20.5, 29):
        img.alpha_composite(fill(arc(ix, iy, r, 282, 336, 4.4), PRIMARY))
    img.alpha_composite(fill(anvil(a_scale, a_dx, a_dy), TEXT))
    img.alpha_composite(fill(h, TEXT))
    img.alpha_composite(fill(circle(ix, iy, 2.8), AMBER))

    img = Image.composite(img, new(), badge)
    return img.resize((N, N), Image.LANCZOS)


if __name__ == "__main__":
    icon = render()
    icon.save(os.path.join(HERE, "streamsmith.png"))
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "streamsmith_256.png"))
    icon.save(os.path.join(HERE, "streamsmith.ico"),
              sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48),
                     (64, 64), (96, 96), (128, 128), (256, 256)])
    print("wrote streamsmith.png, streamsmith_256.png, streamsmith.ico")
