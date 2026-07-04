# /// script
# dependencies = [
#   "pillow",
# ]
# ///
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 600
HEIGHT = 400
TOP = (0xF7, 0xF7, 0xF9)
BOTTOM = (0xEC, 0xEC, 0xF1)
ARROW = (0xC9, 0xC9, 0xD1)
TEXT = (0x8E, 0x8E, 0x93)


def load_font(size: int) -> ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def lerp(start: int, end: int, t: float) -> int:
    return round(start + (end - start) * t)


def draw_background(image: Image.Image) -> None:
    pixels = image.load()
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        color = tuple(lerp(TOP[i], BOTTOM[i], t) for i in range(3))
        for x in range(WIDTH):
            pixels[x, y] = color


def draw_arrow(draw: ImageDraw.ImageDraw) -> None:
    y = 195
    shaft_left = 240
    shaft_right = 334
    shaft_height = 10
    head_tip = 360
    head_half_height = 22

    draw.rounded_rectangle(
        (shaft_left, y - shaft_height // 2, shaft_right, y + shaft_height // 2),
        radius=shaft_height // 2,
        fill=ARROW,
    )
    draw.polygon(
        (
            (shaft_right - 2, y - head_half_height),
            (head_tip, y),
            (shaft_right - 2, y + head_half_height),
        ),
        fill=ARROW,
    )


def draw_caption(draw: ImageDraw.ImageDraw) -> None:
    text = "Drag localvoxtral into Applications"
    font = load_font(15)
    bbox = draw.textbbox((0, 0), text, font=font)
    x = (WIDTH - (bbox[2] - bbox[0])) / 2
    y = 330 - (bbox[3] - bbox[1]) / 2
    draw.text((x, y), text, font=font, fill=TEXT)


def main() -> None:
    output = Path(__file__).resolve().parents[1] / "assets" / "dmg-background.png"
    image = Image.new("RGB", (WIDTH, HEIGHT))
    draw_background(image)
    draw = ImageDraw.Draw(image)
    draw_arrow(draw)
    draw_caption(draw)
    image.save(output, "PNG", optimize=False, compress_level=9)


if __name__ == "__main__":
    main()
