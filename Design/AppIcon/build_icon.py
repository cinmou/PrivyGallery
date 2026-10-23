#!/usr/bin/env python3
"""Build the PrivyGallery Icon Composer layer set.

Every layer is written as a 1024 x 1024 SVG on the same coordinate grid, so the
files can be imported into Icon Composer in the documented order without any
per-layer offset.  Raster previews are produced by rendering the real SVG files
through headless Chromium, so what the check sheet shows is what the vectors say.

Usage:  python3 build_icon.py             # layers + previews
        python3 build_icon.py --install   # also write SecurityFolder/Gallery.icon
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
LAYERS = ROOT / "Layers"
EXPORTS = ROOT / "Exports"
PREVIEW = ROOT / "Preview"
BUNDLE = ROOT.parents[1] / "SecurityFolder" / "Gallery.icon"

CHROMIUM = "/Applications/Chromium.app/Contents/MacOS/Chromium"
CANVAS = 1024

# --------------------------------------------------------------------------
# Geometry.  Ratios traced from the shipping 1024 x 1024 icon; the artwork is
# centred on the canvas (x 158..866, y 176..850).
# --------------------------------------------------------------------------

CARD = {"x0": 158, "y0": 176, "x1": 866, "y1": 780, "r": 110}
DIAL = {"cx": 512, "cy": 700, "r_out": 150, "r_in": 106}
HUB_R = 46
SPOKE_W = 26
SPOKE_LEN = 94                    # from the dial centre outwards
SUN = {"cx": 332, "cy": 337, "r": 66}

# Peak apex, plus the base corners that keep each slope at its traced angle.
# Both slopes run past the card so the album silhouette does the cropping.
FAR_PEAK = (634, 371)
FAR_BASE = ((245, 820), (1064, 820))
NEAR_PEAK = (355, 464)
NEAR_BASE = ((59, 820), (642, 820))
PEAK_ROUND = 40                   # walk-back distance that softens a peak

BACKGROUND_TOP = "#3B4252"
BACKGROUND_BOTTOM = "#21252D"
CARD_FACE_TOP = "#ECEFF4"
CARD_FACE_BOTTOM = "#D8DEE9"
SUN_DISC = "#FFFFFF"
MOUNTAIN_FAR_TOP = "#81A1C1"
MOUNTAIN_FAR_BOTTOM = "#5E81AC"
MOUNTAIN_NEAR_TOP = "#5E81AC"
MOUNTAIN_NEAR_BOTTOM = "#3B5575"
DIAL_FILL = "#2E3440"
HUB_FILL = "#E5E9F0"


def rounded_rect(x0: float, y0: float, x1: float, y1: float, r: float) -> str:
    return (
        f"M {x0 + r},{y0} H {x1 - r} A {r},{r} 0 0 1 {x1},{y0 + r} "
        f"V {y1 - r} A {r},{r} 0 0 1 {x1 - r},{y1} H {x0 + r} "
        f"A {r},{r} 0 0 1 {x0},{y1 - r} V {y0 + r} A {r},{r} 0 0 1 {x0 + r},{y0} Z"
    )


def circle(cx: float, cy: float, r: float) -> str:
    return f"M {cx - r},{cy} a {r},{r} 0 1 0 {2 * r},0 a {r},{r} 0 1 0 {-2 * r},0 Z"


def linear_gradient(ident: str, top: str, bottom: str,
                    y1: float = 0, y2: float = CANVAS) -> str:
    """Vertical gradient; depth without pre-baked shading or highlights."""
    return (
        f'    <linearGradient id="{ident}" gradientUnits="userSpaceOnUse" '
        f'x1="0" y1="{y1}" x2="0" y2="{y2}">\n'
        f'      <stop offset="0" stop-color="{top}"/>\n'
        f'      <stop offset="1" stop-color="{bottom}"/>\n'
        f"    </linearGradient>\n"
    )


CARD_PATH = rounded_rect(CARD["x0"], CARD["y0"], CARD["x1"], CARD["y1"], CARD["r"])
FRAME_INSET = 22
PHOTO_PATH = rounded_rect(
    CARD["x0"] + FRAME_INSET, CARD["y0"] + FRAME_INSET,
    CARD["x1"] - FRAME_INSET, CARD["y1"] - FRAME_INSET,
    CARD["r"] - FRAME_INSET,
)
PUNCH_PATH = circle(DIAL["cx"], DIAL["cy"], DIAL["r_in"])
# The dial opening is cut with a mask (white card, black punch) instead of an
# even-odd path: even-odd fills the part of the punch circle that falls outside
# the card, which leaves a visible half disc under the album's bottom edge.


def peak_path(apex: tuple[float, float], left: tuple[float, float],
              right: tuple[float, float]) -> str:
    """Triangle with a softened apex; the base runs past the card and is clipped."""
    ax, ay = apex

    def walk(p: tuple[float, float]) -> tuple[float, float]:
        dx, dy = p[0] - ax, p[1] - ay
        length = (dx * dx + dy * dy) ** 0.5
        return ax + dx / length * PEAK_ROUND, ay + dy / length * PEAK_ROUND

    lx, ly = walk(left)
    rx, ry = walk(right)
    return (
        f"M {left[0]},{left[1]} L {lx:.2f},{ly:.2f} "
        f"Q {ax},{ay} {rx:.2f},{ry:.2f} L {right[0]},{right[1]} Z"
    )


def svg(body: str, defs: str = "") -> str:
    head = f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">'
    return f"{head}\n{defs}\n{body}\n</svg>\n"


def album_defs(fragment: bool = False) -> str:
    """Mask = album silhouette with the dial opening punched out.

    A mask is used rather than a clip path: Chromium ignores ``clip-rule``
    inside ``clipPath``, which would leave the dial opening filled.  Black
    over white also gives a true intersection; an even-odd path would fill the
    part of the punch circle that falls outside the card.
    """
    body = (
        '    <mask id="album" maskUnits="userSpaceOnUse" x="0" y="0" '
        f'width="{CANVAS}" height="{CANVAS}">\n'
        f'      <path d="{CARD_PATH}" fill="#FFFFFF"/>\n'
        f'      <path d="{circle(DIAL["cx"], DIAL["cy"], DIAL["r_out"])}" fill="#FFFFFF"/>\n'
        f'      <path d="{PUNCH_PATH}" fill="#000000"/>\n'
        "    </mask>"
    )
    return body if fragment else f"  <defs>\n{body}\n  </defs>"


def photo_defs(fragment: bool = False) -> str:
    body = (
        f'<mask id="album" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
        f'<path d="{PHOTO_PATH}" fill="white"/>'
        f'<path d="{circle(DIAL["cx"], DIAL["cy"], DIAL["r_out"])}" fill="black"/>'
        '</mask>'
    )
    return body if fragment else f'<defs>{body}</defs>'


def build_layers() -> list[tuple[str, str]]:
    far = peak_path(FAR_PEAK, *FAR_BASE)
    near = peak_path(NEAR_PEAK, *NEAR_BASE)

    spoke_ends = [
        (DIAL["cx"], DIAL["cy"] - SPOKE_LEN),
        (DIAL["cx"] + SPOKE_LEN * 0.866, DIAL["cy"] + SPOKE_LEN * 0.5),
        (DIAL["cx"] - SPOKE_LEN * 0.866, DIAL["cy"] + SPOKE_LEN * 0.5),
    ]
    spokes = "\n".join(
        f'    <line x1="{DIAL["cx"]}" y1="{DIAL["cy"]}" x2="{x:.2f}" y2="{y:.2f}" '
        f'stroke="{HUB_FILL}" stroke-width="{SPOKE_W}" stroke-linecap="round"/>'
        for x, y in spoke_ends
    )

    layers = [
        (
            "01-background.svg",
            svg(
                f'  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>',
                "  <defs>\n" + linear_gradient("bg", BACKGROUND_TOP, BACKGROUND_BOTTOM) + "  </defs>",
            ),
        ),
        (
            "02-album-card.svg",
            svg(
                f'  <rect width="1024" height="1024" fill="url(#card)" mask="url(#album)"/>',
                "  <defs>\n" + linear_gradient("card", CARD_FACE_TOP, CARD_FACE_BOTTOM, CARD["y0"], CARD["y1"])
                + album_defs(fragment=True) + "\n  </defs>",
            ),
        ),
        (
            "03-album-sun.svg",
            svg(
                f'  <circle cx="{SUN["cx"]}" cy="{SUN["cy"]}" r="{SUN["r"]}" '
                f'fill="{SUN_DISC}" mask="url(#album)"/>',
                photo_defs(),
            ),
        ),
        (
            "04-mountain-far.svg",
            svg(
                f'  <path d="{far}" fill="url(#far)" mask="url(#album)"/>',
                "  <defs>\n" + linear_gradient("far", MOUNTAIN_FAR_TOP, MOUNTAIN_FAR_BOTTOM, FAR_PEAK[1], CARD["y1"])
                + photo_defs(fragment=True) + "\n  </defs>",
            ),
        ),
        (
            "05-mountain-near.svg",
            svg(
                f'  <path d="{near}" fill="url(#near)" mask="url(#album)"/>',
                "  <defs>\n" + linear_gradient("near", MOUNTAIN_NEAR_TOP, MOUNTAIN_NEAR_BOTTOM, NEAR_PEAK[1], CARD["y1"])
                + photo_defs(fragment=True) + "\n  </defs>",
            ),
        ),
        (
            "06-lock-ring.svg",
            svg(
                f'  <circle cx="512" cy="700" r="106" fill="{DIAL_FILL}"/>',
            ),
        ),
        (
            "07-lock-spokes.svg",
            svg(spokes.replace(HUB_FILL, "#8790A3")),
        ),
        (
            "08-lock-hub.svg",
            svg(
                f'  <circle cx="{DIAL["cx"]}" cy="{DIAL["cy"]}" r="{HUB_R}" fill="{HUB_FILL}"/>',
            ),
        ),
    ]
    return layers


# Front to back, the order Icon Composer lists and renders the layers in.
BUNDLE_LAYERS = (
    ("08-lock-hub.png", "Lock Hub"),
    ("07-lock-spokes.png", "Lock Spokes"),
    ("06-lock-ring.png", "Lock Recess"),
    ("05-mountain-near.png", "Near Mountain"),
    ("04-mountain-far.png", "Far Mountain"),
    ("03-album-sun.png", "Sun"),
    ("02-album-card.png", "Album Card"),
)


def srgb(hex_color: str) -> str:
    """``#RRGGBB`` as the ``extended-srgb`` triple Icon Composer writes."""
    value = hex_color.lstrip("#")
    parts = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return "extended-srgb:" + ",".join(f"{c:.5f}" for c in parts) + ",1.00000"


def write_bundle() -> None:
    """Write the `.icon` bundle the app target compiles."""
    assets = BUNDLE / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for stale in assets.iterdir():
        stale.unlink()
    for name, _ in BUNDLE_LAYERS:
        (assets / name).write_bytes((EXPORTS / name).read_bytes())

    layers = [
        {
            "image-name": name,
            "name": label,
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }
        for name, label in BUNDLE_LAYERS
    ]
    manifest = {
        "features": ["specular-location"],
        "fill": {"linear-gradient": [srgb(BACKGROUND_TOP), srgb(BACKGROUND_BOTTOM)]},
        "groups": [
            {
                "name": "Lock",
                "layers": layers[:2] + [dict(layers[2], glass=False)],
                "shadow": {"kind": "neutral", "opacity": 0.18},
                "translucency": {"enabled": False, "value": 0.15},
            },
            {
                "name": "Mountains",
                "layers": layers[3:5],
                "lighting": "individual",
                "specular-specializations": [{"value": "inside"}],
                "shadow": {"kind": "neutral", "opacity": 0.05},
                "translucency": {"enabled": False, "value": 0.15},
            },
            {
                "name": "Album",
                "layers": [dict(layers[5], glass=False), layers[6]],
                "shadow": {"kind": "neutral", "opacity": 0.20},
                "translucency": {"enabled": False, "value": 0.15},
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    manifest_path = BUNDLE / "icon.json"
    if manifest_path.exists() and "--reset-materials" not in sys.argv:
        return
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


# --------------------------------------------------------------------------
# Rasterisation: headless Chromium renders the SVG files, the page hands the
# canvases back as base64 so transparent per-layer PNGs survive.
# --------------------------------------------------------------------------

SIZES = (1024, 512, 256, 128, 64, 32)

RENDER_HTML = """<!doctype html>
<meta charset="utf-8">
<body style="margin:0">
<script>
const files = %(files)s;
const sizes = %(sizes)s;
const images = {};
function load(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('load failed: ' + src));
    img.src = src;
  });
}
function paint(ctx, layers, size) {
  ctx.clearRect(0, 0, size, size);
  for (const img of layers) {
    ctx.drawImage(img, 0, 0, size, size);
  }
}
(async () => {
  const out = { layers: {}, sizes: {} };
  for (const f of files) images[f] = await load('Layers/' + f);
  const layers = files.map(f => images[f]);
  for (const f of files) {
    const c = document.createElement('canvas');
    c.width = c.height = 1024;
    paint(c.getContext('2d'), [images[f]], 1024);
    out.layers[f] = c.toDataURL('image/png').split(',')[1];
  }
  for (const s of sizes) {
    const c = document.createElement('canvas');
    c.width = c.height = s;
    const ctx = c.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    paint(ctx, layers, s);
    out.sizes[s] = c.toDataURL('image/png').split(',')[1];
  }
  const pre = document.createElement('pre');
  pre.id = 'out';
  pre.textContent = JSON.stringify(out);
  document.body.appendChild(pre);
})().catch(err => {
  const box = document.createElement('pre');
  box.id = 'fail';
  box.textContent = String(err && err.stack || err);
  document.body.appendChild(box);
});
</script>
</body>
"""


def render(layer_files: list[str]) -> dict:
    html = ROOT / "_render.html"
    html.write_text(RENDER_HTML % {
        "files": json.dumps(layer_files),
        "sizes": json.dumps(list(SIZES)),
    })
    dom = subprocess.run(
        [
            CHROMIUM, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--allow-file-access-from-files", "--virtual-time-budget=20000",
            "--dump-dom", html.as_uri(),
        ],
        capture_output=True, text=True, timeout=180, check=True,
    ).stdout
    html.unlink()
    marker = '<pre id="out">'
    start = dom.find(marker)
    if start < 0:
        sys.exit("render failed: page did not return canvas data")
    payload = dom[start + len(marker): dom.find("</pre>", start)]
    payload = payload.replace("&quot;", '"').replace("&amp;", "&")
    return json.loads(payload)


def legibility_sheet() -> None:
    """Native sizes beside 6x nearest-neighbour zooms, on the dark desktop."""
    scale, pad, gap = 6, 30, 24
    sizes = (32, 64, 128)
    native_row_h = 128
    zoom_row_h = max(sizes) * scale
    width = sum(s * scale for s in sizes) + gap * (len(sizes) - 1) + pad * 2
    height = pad + 22 + native_row_h + 24 + 22 + zoom_row_h + pad
    sheet = Image.new("RGB", (width, height), (34, 38, 46))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.load_default(size=16)
    except TypeError:                                     # Pillow < 10.1
        font = ImageFont.load_default()

    def load(size: int) -> Image.Image:
        return Image.open(PREVIEW / "sizes" / f"icon-{size}.png").convert("RGBA")

    top = pad
    draw.text((pad, top), "Native size on a dark desktop", fill=(214, 218, 226), font=font)
    x = pad
    for size in sizes:
        icon = load(size)
        sheet.paste(icon, (x, top + 22 + native_row_h - size), icon)
        x += size + gap

    top += 22 + native_row_h + 24
    draw.text((pad, top), f"{scale}x pixel zoom", fill=(214, 218, 226), font=font)
    x = pad
    for size in sizes:
        icon = load(size).resize((size * scale, size * scale), Image.NEAREST)
        sheet.paste(icon, (x, top + 22), icon)
        x += size * scale + gap

    sheet.save(PREVIEW / "legibility-sheet.png")


def write_launch_logo() -> None:
    """Reuse the foreground vectors without the system icon enclosure."""
    artwork = Image.new("RGBA", (CANVAS, CANVAS))
    for name, _ in reversed(BUNDLE_LAYERS):
        artwork = Image.alpha_composite(artwork, Image.open(EXPORTS / name).convert("RGBA"))
    artwork = artwork.crop(artwork.getbbox())
    artwork.thumbnail((832, 832), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS))
    canvas.alpha_composite(artwork, ((CANVAS - artwork.width) // 2, (CANVAS - artwork.height) // 2))
    assets = BUNDLE.parent / "Assets.xcassets" / "LaunchLogo.imageset"
    manifest = json.loads((assets / "Contents.json").read_text())
    for entry in manifest["images"]:
        filename = entry.get("filename")
        if filename:
            (assets / filename).unlink(missing_ok=True)
        scale = int(entry["scale"][0])
        filename = f"LaunchLogo@{scale}x.png"
        canvas.resize((229 * scale, 229 * scale), Image.Resampling.LANCZOS).save(assets / filename)
        entry["filename"] = filename
    (assets / "Contents.json").write_text(json.dumps(manifest, indent=2, separators=(",", " : ")) + "\n")


def main() -> None:
    for directory in (LAYERS, EXPORTS, PREVIEW / "sizes"):
        directory.mkdir(parents=True, exist_ok=True)

    layers = build_layers()
    for name, markup in layers:
        (LAYERS / name).write_text(markup)
    names = [name for name, _ in layers]

    data = render(names)
    for name, payload in data["layers"].items():
        (EXPORTS / name.replace(".svg", ".png")).write_bytes(base64.b64decode(payload))
    for size, payload in data["sizes"].items():
        blob = base64.b64decode(payload)
        name = "icon-1024.png" if size == "1024" else f"sizes/icon-{size}.png"
        (PREVIEW / name).write_bytes(blob)

    legibility_sheet()
    print(f"wrote {len(names)} layers, {len(data['sizes'])} preview sizes")
    if "--install" in sys.argv:
        write_bundle()
        write_launch_logo()
        print(f"installed {BUNDLE.relative_to(BUNDLE.parents[2])}")


if __name__ == "__main__":
    main()
