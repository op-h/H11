"""Generates every H11 icon from one definition.

App icon: deep navy tile, "H11" in bold white, a four-color bar beneath
(cobalt, emerald, saffron, rose), the same colors as the in-app mark.
Tray / tiny sizes: the 2x2 color-tile mark alone.
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, 'assets', 'fonts', 'IBMPlexSansArabic-Bold.ttf')
NAVY = (15, 26, 46, 255)
WHITE = (255, 255, 255, 255)
COLORS = [(36, 80, 230, 255), (15, 157, 107, 255), (227, 160, 8, 255), (208, 47, 90, 255)]
SS = 4


def wordmark(d, size, scale=1.0, color=WHITE, bar=True):
    """Draws H11 + color bar centred in a size×size canvas."""
    font = ImageFont.truetype(FONT, int(size * 0.34 * scale))
    text = 'H11'
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    w, h = r - l, b - t
    bar_h = size * 0.045 * scale
    gap = size * 0.07 * scale
    total = h + (gap + bar_h if bar else 0)
    x = (size - w) / 2 - l
    y = (size - total) / 2 - t
    d.text((x, y), text, font=font, fill=color)
    if bar:
        by = (size - total) / 2 + h + gap
        seg = w / 4
        for i, c in enumerate(COLORS):
            d.rectangle([(size - w) / 2 + i * seg, by, (size - w) / 2 + (i + 1) * seg, by + bar_h], fill=c)


def tiles(d, size, scale=1.0):
    s = size * 0.62 * scale
    g = s * 0.12
    t = (s - g) / 2
    ox = oy = (size - s) / 2
    for i, c in enumerate(COLORS):
        x = ox + (i % 2) * (t + g)
        y = oy + (i // 2) * (t + g)
        d.rounded_rectangle([x, y, x + t, y + t], radius=t * 0.22, fill=c)


def render(size, kind='word', bg=NAVY, rounded=0.0, scale=1.0):
    big = size * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if bg is not None:
        if rounded:
            d.rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * rounded), fill=bg)
        else:
            d.rectangle([0, 0, big, big], fill=bg)
    if kind == 'word':
        wordmark(d, big, scale)
    elif kind == 'mono':
        wordmark(d, big, scale, color=WHITE, bar=False)
    else:
        tiles(d, big, scale)
    return img.resize((size, size), Image.LANCZOS)


def main():
    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    for name, k in dens.items():
        d = os.path.join(res, f'mipmap-{name}')
        os.makedirs(d, exist_ok=True)
        # Phone: plain and clear. Solid navy, bold white H11, no colors.
        render(int(48 * k), kind='mono', rounded=0.22, scale=1.15).save(os.path.join(d, 'ic_launcher.png'))
        # Adaptive: content kept inside the 66/108 safe zone.
        render(int(108 * k), kind='mono', bg=None, scale=0.72).save(
            os.path.join(d, 'ic_launcher_foreground.png'))
        render(int(108 * k), kind='mono', bg=None, scale=0.72).save(
            os.path.join(d, 'ic_launcher_monochrome.png'))
    anydpi = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
                '</adaptive-icon>\n')

    # Windows .ico: wordmark for large sizes, color tiles where text can't read.
    big = render(256, rounded=0.2)
    ico = os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico')
    small = {s: render(s, kind='tiles', rounded=0.2) for s in (16, 20, 24, 32)}
    large = {s: render(s, rounded=0.2) for s in (40, 48, 64, 128)}
    imgs = {**small, **large, 256: big}
    big.save(ico, sizes=[(s, s) for s in imgs], append_images=[imgs[s] for s in sorted(imgs) if s != 256])
    os.makedirs(os.path.join(ROOT, 'assets', 'icon'), exist_ok=True)
    render(256, kind='tiles', bg=None, scale=1.5).save(
        os.path.join(ROOT, 'assets', 'icon', 'tray.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48)])
    render(512, rounded=0.2).save(os.path.join(ROOT, 'assets', 'icon', 'icon_512.png'))
    # One-color variants: the app picks one at each launch (Windows window/tray).
    palette = [(36, 80, 230, 255), (15, 157, 107, 255), (227, 160, 8, 255),
               (208, 47, 90, 255), (11, 156, 216, 255), (19, 163, 160, 255)]
    global COLORS
    saved = COLORS
    for i, col in enumerate(palette):
        COLORS = [col] * 4
        render(256, kind='tiles', bg=None, scale=1.5).save(
            os.path.join(ROOT, 'assets', 'icon', f'tray_{i}.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48)])
        render(256, kind='tiles', rounded=0.2).save(
            os.path.join(ROOT, 'assets', 'icon', f'app_{i}.ico'), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (256, 256)])
    COLORS = saved
    print('icons written')


if __name__ == '__main__':
    main()
