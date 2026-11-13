"""Generate Vesper branding assets. Run: python -I tool/generate_icon.py
Concept: an evening star (Vesper) guarding a vault (shield) with a V chevron.
Outputs to assets/branding/: icon_1024.png, icon_foreground.png, logo_mark.png
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 4096
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'branding')

def hexc(h):
    h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def gradient(size, c1, c2, diag=True):
    """Diagonal (top-left c1 -> bottom-right c2) gradient, RGB."""
    g = Image.linear_gradient('L').resize((size, size))  # black top -> white bottom
    if diag:
        h = Image.linear_gradient('L').rotate(90).resize((size, size))  # horizontal
        g = ImageChops.add(g.point(lambda v: v // 2), h.point(lambda v: v // 2))
    return Image.composite(Image.new('RGB', (size, size), c2), Image.new('RGB', (size, size), c1), g)

def bez(p0, p1, p2, p3, n=200):
    pts = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        pts.append((u**3*p0[0]+3*u*u*t*p1[0]+3*u*t*t*p2[0]+t**3*p3[0],
                    u**3*p0[1]+3*u*u*t*p1[1]+3*u*t*t*p2[1]+t**3*p3[1]))
    return pts

def shield_points(cx, cy, w, h):
    """Rounded-top shield with pointed bottom. w,h = full width/height."""
    hw, top, bot = w / 2, cy - h / 2, cy + h / 2
    r = w * 0.16
    side_end = top + h * 0.50
    pts = []
    # top-left rounded corner -> top edge -> top-right corner
    for a in range(180, 271, 2):
        pts.append((cx - hw + r + r*math.cos(math.radians(a)), top + r + r*math.sin(math.radians(a))))
    for a in range(270, 361, 2):
        pts.append((cx + hw - r + r*math.cos(math.radians(a)), top + r + r*math.sin(math.radians(a))))
    # right side down, then curve to bottom tip
    pts.append((cx + hw, side_end))
    pts += bez((cx + hw, side_end), (cx + hw, top + h*0.80), (cx + w*0.18, bot - h*0.10), (cx, bot))
    pts += bez((cx, bot), (cx - w*0.18, bot - h*0.10), (cx - hw, top + h*0.80), (cx - hw, side_end))
    return pts

def star_points(cx, cy, rx, ry, n=240):
    """Concave four-pointed star (astroid), vertically elongated."""
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        pts.append((cx + rx * math.cos(t)**3, cy + ry * math.sin(t)**3))
    return pts

def draw_mark(size, mark_h):
    """Transparent RGBA layer (size x size) with shield+star centred; mark_h = shield height in px."""
    cx, cy = size / 2, size / 2
    h = mark_h; w = h * 0.86
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    # soft drop shadow
    sh = Image.new('L', (size, size), 0)
    ImageDraw.Draw(sh).polygon(shield_points(cx, cy + h*0.02, w, h), fill=120)
    sh = sh.filter(ImageFilter.GaussianBlur(h * 0.03))
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0)); shadow.putalpha(sh)
    layer = Image.alpha_composite(layer, shadow)
    # shield body with gradient
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).polygon(shield_points(cx, cy, w, h), fill=255)
    grad = gradient(size, hexc('#00A884'), hexc('#1FC7A3')).convert('RGBA')
    body = Image.new('RGBA', (size, size), (0, 0, 0, 0)); body.paste(grad, (0, 0), mask)
    layer = Image.alpha_composite(layer, body)
    # inner darker shield inset (depth ring)
    inner = Image.new('L', (size, size), 0)
    ImageDraw.Draw(inner).polygon(shield_points(cx, cy, w*0.86, h*0.86), fill=255)
    ring = ImageChops.subtract(mask, inner)
    ringl = Image.new('RGBA', (size, size), hexc('#FFFFFF') + (0,))
    ringl.putalpha(ring.point(lambda v: v // 8))
    layer = Image.alpha_composite(layer, ringl)
    # V chevron (dark teal) in lower part
    d = Image.new('L', (size, size), 0); dd = ImageDraw.Draw(d)
    lw = int(h * 0.055)
    a = (cx - w*0.20, cy + h*0.17); b = (cx, cy + h*0.34); c = (cx + w*0.20, cy + h*0.17)
    dd.line([a, b, c], fill=255, width=lw, joint='curve')
    for p in (a, c):
        dd.ellipse([p[0]-lw/2, p[1]-lw/2, p[0]+lw/2, p[1]+lw/2], fill=255)
    chev = Image.new('RGBA', (size, size), hexc('#006B58') + (0,)); chev.putalpha(d.point(lambda v: int(v*0.75)))
    layer = Image.alpha_composite(layer, chev)
    # star glow
    scx, scy = cx, cy - h*0.16
    glow = Image.new('L', (size, size), 0)
    ImageDraw.Draw(glow).polygon(star_points(scx, scy, h*0.19, h*0.27), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(h * 0.05))
    gl = Image.new('RGBA', (size, size), hexc('#FFE9A8') + (0,)); gl.putalpha(glow.point(lambda v: int(v*0.55)))
    layer = Image.alpha_composite(layer, gl)
    # star
    sm = Image.new('L', (size, size), 0)
    ImageDraw.Draw(sm).polygon(star_points(scx, scy, h*0.18, h*0.26), fill=255)
    st = Image.new('RGBA', (size, size), hexc('#FFF6D8') + (0,)); st.putalpha(sm)
    # keep only star inside shield
    layer = Image.alpha_composite(layer, st)
    return layer

def down(img, s):
    return img.resize((s, s), Image.LANCZOS)

def main():
    os.makedirs(OUT, exist_ok=True)
    # full-bleed icon
    bg = gradient(SS, hexc('#0B141A'), hexc('#12303A')).convert('RGBA')
    icon = Image.alpha_composite(bg, draw_mark(SS, SS * 0.62))
    down(icon, 1024).convert('RGB').save(os.path.join(OUT, 'icon_1024.png'))
    # adaptive foreground: flutter_launcher_icons wraps it in a 16% inset, so 84% here ~= 57% of the 108dp canvas (inside the 66dp safe zone)
    fg = draw_mark(SS, SS * 0.84)
    down(fg, 1024).save(os.path.join(OUT, 'icon_foreground.png'))
    # logo mark: tight crop of a large mark, 512px
    big = draw_mark(SS, SS * 0.80)
    bbox = big.getbbox()
    side = max(bbox[2]-bbox[0], bbox[3]-bbox[1]) + 80
    mcx, mcy = (bbox[0]+bbox[2])//2, (bbox[1]+bbox[3])//2
    crop = big.crop((mcx-side//2, mcy-side//2, mcx+side//2, mcy+side//2))
    crop.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, 'logo_mark.png'))

if __name__ == '__main__':
    main()
