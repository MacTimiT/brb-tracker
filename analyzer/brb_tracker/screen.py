"""Screen profiles: spatial/color checks before OCR, never chat classification."""
from PIL import Image, ImageOps

PROFILES = ("full_frame", "gamin4hope")


def prepare_screen(frame: Image.Image, profile: str = "full_frame") -> Image.Image | None:
    if profile not in PROFILES:
        raise ValueError("Unknown screen detector profile")
    if profile == "full_frame":
        return ImageOps.autocontrast(ImageOps.grayscale(frame))
    width, height = frame.size
    left = min(int(width * 0.05), width - 1)
    right = max(left + 1, min(int(width * 0.68), width))
    top = min(int(height * 0.68), height - 1)
    region = frame.crop((left, top, right, height)).convert("RGB")
    region = region.resize((960, max(1, int(region.height * 960 / region.width))), Image.Resampling.BILINEAR)
    pixels = region.tobytes()
    mask = bytearray(region.width * region.height)
    red_count = 0
    for index in range(len(mask)):
        r, g, b = pixels[index * 3:index * 3 + 3]
        red = r >= 120 and r * 10 >= g * 16 and r * 10 >= b * 14
        mask[index] = 0 if red else 255
        red_count += red
    if red_count < max(12, int(len(mask) * 0.001)):
        return None
    return Image.frombytes("L", region.size, bytes(mask))
