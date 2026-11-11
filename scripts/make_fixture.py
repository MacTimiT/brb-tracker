"""Generate a 24-second test VOD; never represents real streamer activity."""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else "data/fixture")
    folder.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype("DejaVuSans-Bold.ttf", 54)
    for name, text in [("active", "LIVE GAMEPLAY"), ("brb", "BE RIGHT BACK")]:
        image = Image.new("RGB", (960, 540), "#101827")
        draw = ImageDraw.Draw(image)
        draw.text((480, 270), text, font=font, fill="white", anchor="mm")
        image.save(folder / f"{name}.png")
    # 0-6 gameplay, 6-14 BRB, 14-20 gameplay, 20-24 BRB (EOF).
    files = "".join(f"file '{name}.png'\nduration {duration}\n" for name, duration in [("active", 6), ("brb", 8), ("active", 6), ("brb", 4)]) + "file 'brb.png'\n"
    (folder / "frames.txt").write_text(files)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(folder / "frames.txt"),
                    "-t", "24", "-r", "10", "-pix_fmt", "yuv420p", str(folder / "synthetic.mp4")], check=True)
    (folder / "transcript.json").write_text(json.dumps([
        {"start": 2, "end": 4, "text": "I need to pee. Be right back."},
        {"start": 16, "end": 18, "text": "I'm going to grab a snack."},
    ], indent=2))
    print(folder / "synthetic.mp4")


if __name__ == "__main__":
    main()
