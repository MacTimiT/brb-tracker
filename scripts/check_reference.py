"""Check a supplied reference locally without copying it into the repository."""
import json
import sys

import pytesseract
from PIL import Image

from brb_tracker.detection import is_brb
from brb_tracker.screen import prepare_screen


def main():
    reference = Image.open(sys.argv[1]).convert("RGB")
    outcomes = []
    for width in [1280, 960, 480, 360]:
        frame = reference.resize((width, max(1, int(reference.height * width / reference.width))), Image.Resampling.BILINEAR)
        image = prepare_screen(frame, "gamin4hope")
        text = pytesseract.image_to_string(image, config="--psm 11") if image is not None else ""
        outcomes.append({"width": width, "recognized": text.strip(), "match": is_brb(text)})
    print(json.dumps(outcomes, indent=2))
    raise SystemExit(0 if all(item["match"] for item in outcomes) else 1)


if __name__ == "__main__":
    main()
