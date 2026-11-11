import pytest
import pytesseract
from PIL import Image, ImageDraw, ImageFont

from brb_tracker.detection import is_brb
from brb_tracker.screen import prepare_screen


def banner_frame(*, banner=True, color="#f20909", chat=True):
    frame = Image.new("RGB", (1280, 720), "#110c20")
    draw = ImageDraw.Draw(frame)
    draw.rectangle((900, 0, 1279, 719), fill="#050505")
    if banner:
        draw.text((120, 620), "Be Right Back", font=ImageFont.truetype("DejaVuSans.ttf", 54), fill=color, stroke_width=2, stroke_fill="white", anchor="lt")
    if chat:
        draw.text((940, 520), "Be Right Back", font=ImageFont.truetype("DejaVuSans.ttf", 24), fill="#ff1010", anchor="lt")
    if not banner:
        # Unrelated red gameplay/UI pixels must not make chat text count.
        draw.rectangle((140, 550, 175, 575), fill="#ff1010")
    return frame


@pytest.mark.parametrize("width", [1280, 960, 480, 360])
def test_red_lower_left_banner_survives_downscaling(width):
    frame = banner_frame().resize((width, int(720 * width / 1280)), Image.Resampling.BILINEAR)
    mask = prepare_screen(frame, "gamin4hope")
    assert mask is not None
    assert is_brb(pytesseract.image_to_string(mask, config="--psm 11"))


def test_chat_only_phrase_cannot_trigger_banner_profile():
    frame = banner_frame(banner=False)
    # Whole-frame OCR can see the phrase in chat; the banner profile excludes it.
    assert is_brb(pytesseract.image_to_string(prepare_screen(frame), config="--psm 11"))
    mask = prepare_screen(frame, "gamin4hope")
    assert mask is not None
    assert not is_brb(pytesseract.image_to_string(mask, config="--psm 11"))


def test_white_banner_requires_generic_profile_and_invalid_profiles_fail():
    frame = banner_frame(color="white", chat=False)
    assert prepare_screen(frame, "gamin4hope") is None
    assert is_brb(pytesseract.image_to_string(prepare_screen(frame), config="--psm 11"))
    with pytest.raises(ValueError):
        prepare_screen(frame, "typo")
