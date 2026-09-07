"""render.py -- turn captured terminal snapshots into PNGs that look like a
real ComputerCraft screen (6x9 cells, exact 2x3 sub-pixel drawing characters).

usage: python render.py out/<stem>.shots [scale]
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

CELL_W, CELL_H = 6, 9
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\consola.ttf",
    r"C:\Windows\Fonts\cour.ttf",
    r"C:\Windows\Fonts\lucon.ttf",
]


def load_font(scale):
    size = max(6, int(CELL_H * scale * 0.92))
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def parse(path):
    with open(path, "r", encoding="latin1") as fh:
        raw = fh.read().split("\n")
    shots, cur = [], None
    for line in raw:
        if line.startswith("@@"):
            cur = {"name": line[2:], "lines": []}
            shots.append(cur)
        elif cur is not None:
            cur["lines"].append(line)
    return shots


def render(shot, scale, font):
    lines = shot["lines"]
    w, h = (int(v) for v in lines[0].split())
    palette = [int(v, 16) for v in lines[1].split()]
    rgb = [((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in palette]
    cw, ch = CELL_W * scale, CELL_H * scale
    img = Image.new("RGB", (w * cw, h * ch), rgb[15])
    d = ImageDraw.Draw(img)

    for y in range(h):
        parts = lines[2 + y].split(" ")
        codes = parts[0]
        fgs, bgs = parts[1], parts[2]
        for x in range(w):
            code = int(codes[x * 2:x * 2 + 2], 16)
            fg = rgb[int(fgs[x], 16)]
            bg = rgb[int(bgs[x], 16)]
            px, py = x * cw, y * ch
            d.rectangle([px, py, px + cw - 1, py + ch - 1], fill=bg)
            if 128 <= code <= 159:
                bits = code - 128
                for sy in range(3):
                    for sx in range(2):
                        if bits & (1 << (sy * 2 + sx)):
                            x0 = px + sx * (cw // 2)
                            y0 = py + sy * (ch // 3)
                            d.rectangle(
                                [x0, y0, x0 + cw // 2 - 1, y0 + ch // 3 - 1], fill=fg)
            elif code != 32:
                glyph = chr(code)
                bbox = d.textbbox((0, 0), glyph, font=font)
                gw = bbox[2] - bbox[0]
                gh = bbox[3] - bbox[1]
                d.text((px + (cw - gw) / 2 - bbox[0], py + (ch - gh) / 2 - bbox[1]),
                       glyph, font=font, fill=fg)
    return img


def main():
    src = sys.argv[1]
    scale = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    font = load_font(scale)
    outdir = os.path.join(os.path.dirname(src) or ".", "img")
    os.makedirs(outdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(src))[0]
    shots = parse(src)
    made = []
    for shot in shots:
        img = render(shot, scale, font)
        p = os.path.join(outdir, f"{stem}-{shot['name']}.png")
        img.save(p)
        made.append(p)
    if len(made) > 1:
        cols = min(2, len(made))
        rows = (len(made) + cols - 1) // cols
        tiles = [Image.open(p) for p in made]
        tw, th = tiles[0].size
        pad = 8
        sheet = Image.new("RGB", (cols * tw + (cols + 1) * pad,
                                  rows * th + (rows + 1) * pad), (24, 24, 28))
        for i, t in enumerate(tiles):
            cx, cy = i % cols, i // cols
            sheet.paste(t, (pad + cx * (tw + pad), pad + cy * (th + pad)))
        sheet_path = os.path.join(outdir, f"{stem}-sheet.png")
        sheet.save(sheet_path)
        made.append(sheet_path)
    print("\n".join(made))


if __name__ == "__main__":
    main()
