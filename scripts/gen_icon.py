"""Dessine l'icône d'AppliTransport (repère de carte blanc contenant un bus, sur fond bleu-vert)
et produit les fichiers Android : icône classique et icône adaptative (Android 8+).

Usage : python3 scripts/gen_icon.py      (nécessite Pillow ; image de référence : appli/icone/icone_1024.png)
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "appli" / "android" / "app" / "src" / "main" / "res"
OUT = ROOT / "appli" / "icone"
TEAL, TEAL_LIGHT, WHITE, AMBER = (27, 94, 122), (38, 132, 160), (255, 255, 255), (255, 193, 7)
S = 4  # sur-échantillonnage pour des bords lisses


def background(size):
    """Dégradé vertical bleu-vert."""
    img = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TEAL_LIGHT, TEAL)) + (255,))
    return img


def foreground(size, scale):
    """Repère de carte + bus, centré, occupant [scale] de la largeur."""
    big = size * S
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w = big * scale
    cx, top = big / 2, (big - w * 1.22) / 2  # le repère est plus haut que large
    r = w / 2
    cy = top + r
    # repère : disque + pointe vers le bas, avec une ombre douce décalée
    for dx, dy, color in [(0.025 * w, 0.03 * w, (0, 0, 0, 60)), (0, 0, WHITE + (255,))]:
        d.ellipse([cx - r + dx, cy - r + dy, cx + r + dx, cy + r + dy], fill=color)
        d.polygon([(cx - r * 0.72 + dx, cy + r * 0.62 + dy), (cx + r * 0.72 + dx, cy + r * 0.62 + dy),
                   (cx + dx, top + w * 1.22 + dy)], fill=color)
    # bus vu de face, dans le disque
    bw, bh = r * 1.08, r * 1.12
    bx, by = cx - bw / 2, cy - bh / 2 - r * 0.04
    d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=bw * 0.16, fill=TEAL + (255,))
    # pare-brise
    m = bw * 0.1
    d.rounded_rectangle([bx + m, by + bh * 0.14, bx + bw - m, by + bh * 0.56], radius=bw * 0.06, fill=WHITE + (255,))
    # girouette (bandeau du haut)
    d.rounded_rectangle([bx + bw * 0.25, by + bh * 0.04, bx + bw * 0.75, by + bh * 0.1], radius=bw * 0.03,
                        fill=AMBER + (255,))
    # phares
    pr = bw * 0.075
    for px in (bx + bw * 0.22, bx + bw * 0.78):
        d.ellipse([px - pr, by + bh * 0.74 - pr, px + pr, by + bh * 0.74 + pr], fill=AMBER + (255,))
    # roues
    ww, wh = bw * 0.2, bh * 0.14
    for wx in (bx + bw * 0.12, bx + bw * 0.68):
        d.rounded_rectangle([wx, by + bh - wh * 0.35, wx + ww, by + bh + wh * 0.65], radius=ww * 0.3,
                            fill=(20, 60, 80, 255))
    return img.resize((size, size), Image.LANCZOS)


def rounded(img, radius_ratio=0.22):
    """Masque carré à coins arrondis (icône classique et aperçu)."""
    size = img.size[0]
    mask = Image.new("L", (size * S, size * S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * S - 1, size * S - 1], radius=size * S * radius_ratio, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask.resize(img.size, Image.LANCZOS))
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    full = background(1024)
    full.alpha_composite(foreground(1024, 0.56))
    rounded(full).save(OUT / "icone_1024.png")

    # icône classique (Android < 8) : mipmap-*/ic_launcher.png
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        d = RES / f"mipmap-{density}"
        d.mkdir(parents=True, exist_ok=True)
        rounded(full).resize((px, px), Image.LANCZOS).save(d / "ic_launcher.png")
        # icône adaptative : premier plan 108 dp dont seuls les 72 dp centraux sont toujours visibles
        fg = foreground(px * 108 // 48, 0.44)
        fg.save(d / "ic_launcher_foreground.png")
    (RES / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
    (RES / "mipmap-anydpi-v26" / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n')
    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values" / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">#{TEAL[0]:02X}{TEAL[1]:02X}{TEAL[2]:02X}</color>\n</resources>\n')

    # aperçus : icône classique, ronde et carrée (découpes de l'icône adaptative)
    bg = Image.new("RGBA", (432, 432), TEAL + (255,))
    bg.alpha_composite(foreground(432, 0.44))
    sheet = Image.new("RGBA", (3 * 300 + 40, 300), (240, 240, 240, 255))
    sheet.alpha_composite(rounded(full).resize((260, 260), Image.LANCZOS), (10, 20))
    circle = Image.new("L", (432, 432), 0)
    ImageDraw.Draw(circle).ellipse([36, 36, 396, 396], fill=255)
    c = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    c.paste(bg, (0, 0), circle)
    sheet.alpha_composite(c.crop((36, 36, 396, 396)).resize((260, 260), Image.LANCZOS), (330, 20))
    sheet.alpha_composite(rounded(bg.crop((36, 36, 396, 396)), 0.18).resize((260, 260), Image.LANCZOS), (650, 20))
    sheet.save(OUT / "apercu.png")
    print(f"icônes générées dans {RES} ; aperçu : {OUT / 'apercu.png'}")


if __name__ == "__main__":
    main()
