#!/usr/bin/env python3
"""Regenerate the README's device-framed product shots.

Composes a MacBook shell around `apps/web/public/media/hero.png` and iPhone
shells around `apps/web/public/media/ios-sessions.png` /
`ios-terminal.png`, then writes the results to `docs/media/`. GitHub strips
CSS from rendered READMEs, so the device chrome has to be baked into the
PNGs themselves rather than drawn with a wrapper + box-shadow in HTML.

The source screenshots already contain their own chrome (macOS traffic
lights top-left in hero.png; iOS status bar + Dynamic Island in the phone
shots), so the shells drawn here are deliberately "dumb": a MacBook lid is
just bezel + rounded top corners (no titlebar), and a phone is just the
metal rail + side buttons (no notch cutout). Drawing either would
duplicate chrome that is already baked into the screenshot.

Every shape is drawn at `SUPERSAMPLE`x the final pixel size and downscaled
once with LANCZOS at the very end of each composite, so rounded corners and
tapered edges stay smooth instead of jagged. Run with no arguments:

    python3 scripts/make-readme-device-art.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = Path(__file__).resolve().parent.parent
MEDIA_DIR = REPO_ROOT / "apps" / "web" / "public" / "media"
OUT_DIR = REPO_ROOT / "docs" / "media"

HERO_PATH = MEDIA_DIR / "hero.png"
IOS_SESSIONS_PATH = MEDIA_DIR / "ios-sessions.png"
IOS_TERMINAL_PATH = MEDIA_DIR / "ios-terminal.png"

DEVICES_OUT_PATH = OUT_DIR / "readme-devices.png"
IOS_OUT_PATH = OUT_DIR / "readme-ios.png"

# Everything is drawn this many times larger than the final pixel size, then
# downscaled once with LANCZOS. That's what keeps rounded corners and the
# tapered MacBook base smooth instead of jagged.
SUPERSAMPLE = 4

DEVICES_FINAL_WIDTH = 1800
IOS_FINAL_WIDTH = 1000

# Neutral device greys, chosen to read cleanly on both GitHub's light and
# dark theme (no near-white and no near-black that would flatten into the
# page background). Both the MacBook and the iPhone shell share this one
# dark-aluminium palette -- BEZEL_COLOR/RAIL_HIGHLIGHT/MAC_LIGHT are the
# Mac's own bezel/hinge/deck tones; METAL_MID exists only for the phone
# rail's darker mid-band, which needs to stay dark enough to read as a
# shadow without dropping all the way to PHONE_BEZEL_COLOR's near-black --
# collapsing that gap is what makes a dark rail look like flat dark plastic.
BEZEL_COLOR = (28, 31, 32)  # #1c1f20 -- Mac lid bezel
RAIL_HIGHLIGHT = (58, 65, 67)  # #3a4143 -- brightest hinge/rail highlight
MAC_LIGHT = (74, 77, 82)  # #4a4d52 -- deck / rail mid-light tone
METAL_MID = (53, 55, 59)  # #35373b -- darker mid-band, phone rail only
MAC_BASE_FRONT_DARK = (18, 20, 21)  # darker than BEZEL_COLOR -- the base's
# bottom front edge, where the deck should read darkest.
HINGE_LINE_COLOR = (10, 11, 12)  # thin dark seam at the very bottom of the
# lid, where it meets the base -- what makes the two pieces read as hinged
# rather than as one continuous slab.
SCREEN_BACKING = (12, 14, 15)  # #0c0e0f

# The phone's black bezel -- what actually separates the metal rail from the
# glass on a real device -- uses its own near-black distinct from
# BEZEL_COLOR so it reads darker than the Mac's bezel/hinge tones.
PHONE_BEZEL_COLOR = (8, 8, 9)  # #080809

SHADOW_ALPHA = 0.24  # low-alpha soft grounding shadow; anything heavier
# reads as a grey box on GitHub's light theme. Shared by both shells now
# that they're the same dark-aluminium tone.
RAIL_CONTOUR = (72, 75, 80)  # thin stroke traced at the rail's true outer
# edge -- keeps a crisp silhouette against GitHub's dark theme (#0d1117),
# where a dark-aluminium rail alone has little contrast against the page.


def _int_box(box: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
    return tuple(round(v) for v in box)  # type: ignore[return-value]


def gradient_column(height: int, stops: list[tuple[float, tuple[int, int, int]]]) -> list[tuple[int, int, int]]:
    """Interpolate an RGB color for each row of a vertical gradient.

    `stops` is a list of (position 0..1, RGB) pairs, sorted ascending.
    """
    stops = sorted(stops, key=lambda s: s[0])
    colors: list[tuple[int, int, int]] = []
    for i in range(height):
        t = i / (height - 1) if height > 1 else 0.0
        for j in range(len(stops) - 1):
            p0, c0 = stops[j]
            p1, c1 = stops[j + 1]
            if t <= p1 or j == len(stops) - 2:
                local_t = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
                local_t = min(1.0, max(0.0, local_t))
                colors.append(
                    (
                        round(c0[0] + (c1[0] - c0[0]) * local_t),
                        round(c0[1] + (c1[1] - c0[1]) * local_t),
                        round(c0[2] + (c1[2] - c0[2]) * local_t),
                    )
                )
                break
    return colors


def vertical_gradient_image(width: int, height: int, stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    """An RGB image with a vertical gradient (constant across each row)."""
    column = gradient_column(height, stops)
    col_img = Image.new("RGB", (1, height))
    col_img.putdata(column)
    return col_img.resize((width, height), Image.NEAREST)


def add_ground_shadow(
    canvas: Image.Image,
    shape_box: tuple[float, float, float, float],
    radius: float,
    blur: float,
    y_offset: float,
    alpha: float = SHADOW_ALPHA,
) -> Image.Image:
    """Composite a soft, low-alpha blurred rounded-rect shadow onto `canvas`."""
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    x0, y0, x1, y1 = shape_box
    draw.rounded_rectangle(
        _int_box((x0, y0 + y_offset, x1, y1 + y_offset)),
        radius=round(radius),
        fill=(0, 0, 0, 255),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    r, g, b, a = shadow.split()
    a = a.point(lambda v: round(v * alpha))
    shadow.putalpha(a)
    return Image.alpha_composite(canvas, shadow)


def mac_frame(screenshot: Image.Image, lid_width: int) -> tuple[Image.Image, dict]:
    """Render a MacBook lid + base shell around `screenshot` at hi-res.

    `screenshot` already contains the macOS traffic lights, so the lid draws
    bezel only -- no titlebar. Returns (sprite, info); `info` gives the
    sprite-local pixel boxes of the lid and the base so a caller can align
    other sprites (e.g. an overlapping phone) against specific device
    features instead of guessing offsets.
    """
    bezel_side = round(lid_width * 0.015)
    bezel_top = bezel_side
    bezel_bottom = round(lid_width * 0.02)
    lid_radius = round(lid_width * 0.016)

    screen_w = lid_width - 2 * bezel_side
    screen_h = round(screen_w * screenshot.height / screenshot.width)
    lid_height = screen_h + bezel_top + bezel_bottom

    # The base's top edge sits flush against the lid (same width, no seam);
    # the bottom (front) edge flares outward for the classic tapered-wedge
    # look. The thumb-scoop lives on that bottom edge: a real MacBook's
    # scoop is a shallow indentation in the *front* of the base, which in
    # this straight-on view is the base's bottom edge, not a hole floating
    # in the middle of the deck.
    base_overhang = round(lid_width * 0.08)  # bottom-edge flare, per side
    base_half_bottom = lid_width / 2 + base_overhang
    base_height = round(lid_width * 0.036)
    scoop_width = base_half_bottom * 2 * 0.16
    scoop_depth = base_height * 0.40

    shadow_blur = lid_width * 0.018
    margin = round(shadow_blur * 3 + lid_width * 0.035)

    canvas_w = round(2 * base_half_bottom + 2 * margin)
    canvas_h = round(lid_height + base_height + 2 * margin)
    cx = canvas_w / 2

    lid_x0 = cx - lid_width / 2
    lid_x1 = cx + lid_width / 2
    lid_y0 = float(margin)
    lid_y1 = lid_y0 + lid_height

    base_y0 = lid_y1
    base_y1 = base_y0 + base_height
    base_top_l, base_top_r = lid_x0, lid_x1
    base_bot_l, base_bot_r = cx - base_half_bottom, cx + base_half_bottom

    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    # Soft grounding shadow beneath the whole silhouette.
    canvas = add_ground_shadow(
        canvas,
        (lid_x0 + lid_width * 0.03, lid_y0, lid_x1 - lid_width * 0.03, base_y1),
        radius=lid_radius,
        blur=shadow_blur,
        y_offset=lid_width * 0.012,
    )

    # --- Base: tapered trapezoid, lighter top edge fading to a darker
    # bottom edge, with a shallow thumb-scoop cut *upward* into the bottom
    # (front) edge. The scoop's cut rectangle is drawn past the outer
    # bottom edge so it merges with the already-transparent exterior --
    # the scoop becomes part of the silhouette's outline instead of a
    # separately-masked hole, so it reads correctly on any background. ---
    base_mask = Image.new("L", (canvas_w, canvas_h), 0)
    bmd = ImageDraw.Draw(base_mask)
    bmd.polygon(
        [
            (base_top_l, base_y0),
            (base_top_r, base_y0),
            (base_bot_r, base_y1),
            (base_bot_l, base_y1),
        ],
        fill=255,
    )
    scoop_l = cx - scoop_width / 2
    scoop_r = cx + scoop_width / 2
    bmd.rounded_rectangle(
        _int_box((scoop_l, base_y1 - scoop_depth, scoop_r, base_y1 + 2)),
        radius=round(scoop_depth * 0.55),
        corners=(True, True, False, False),
        fill=0,
    )

    # Thin hinge highlight right at the top edge, a flat deck mid-tone
    # through the body, then darker toward the bottom front edge -- a broad
    # top-to-bottom wash reads as a seam under the screen rather than a
    # metal deck.
    base_gradient = vertical_gradient_image(
        canvas_w,
        round(base_height),
        [(0.0, RAIL_HIGHLIGHT), (0.15, MAC_LIGHT), (0.85, MAC_LIGHT), (1.0, MAC_BASE_FRONT_DARK)],
    )
    base_rgb = Image.new("RGB", (canvas_w, canvas_h), BEZEL_COLOR)
    base_rgb.paste(base_gradient, (0, round(base_y0)))
    base_layer = base_rgb.convert("RGBA")
    base_layer.putalpha(base_mask)
    canvas = Image.alpha_composite(canvas, base_layer)

    # --- Lid: dark bezel, rounded top corners only (the bottom edge sits
    # flush against the base, so it stays square). A 1px lighter top edge
    # gives the bezel a hint of dimension. ---
    lid_layer = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lid_layer)
    highlight_h = max(SUPERSAMPLE, round(lid_width * 0.0015))
    ld.rounded_rectangle(
        _int_box((lid_x0, lid_y0, lid_x1, lid_y1)),
        radius=lid_radius,
        corners=(True, True, False, False),
        fill=RAIL_HIGHLIGHT + (255,),
    )
    ld.rounded_rectangle(
        _int_box((lid_x0, lid_y0 + highlight_h, lid_x1, lid_y1)),
        radius=max(0, lid_radius - highlight_h),
        corners=(True, True, False, False),
        fill=BEZEL_COLOR + (255,),
    )

    # Hinge line: a thin darker stroke at the very bottom of the lid, where
    # it meets the base -- what makes the two pieces read as a hinged
    # laptop rather than one continuous slab. Sits inside the chin bezel
    # (bezel_bottom), well below the screen, so it never overlaps it.
    hinge_h = max(SUPERSAMPLE, round(lid_width * 0.0015))
    ld.rectangle(
        _int_box((lid_x0, lid_y1 - hinge_h, lid_x1, lid_y1)),
        fill=HINGE_LINE_COLOR + (255,),
    )

    # Screen: inset rectangle, screenshot resized to fit exactly (aspect
    # already matches since screen_h was derived from it) -- no cropping,
    # no distortion, no extra rounding (the source frame is already flat).
    screen_x0 = lid_x0 + bezel_side
    screen_y0 = lid_y0 + bezel_top
    screen_x1 = screen_x0 + screen_w
    screen_y1 = screen_y0 + screen_h
    fitted = screenshot.resize((round(screen_w), round(screen_h)), Image.LANCZOS)
    lid_layer.paste(fitted, (round(screen_x0), round(screen_y0)))

    canvas = Image.alpha_composite(canvas, lid_layer)

    info = {
        "lid_box": (lid_x0, lid_y0, lid_x1, lid_y1),
        "base_bottom_box": (base_bot_l, base_y0, base_bot_r, base_y1),
        "margin": margin,
    }
    return canvas, info


def phone_frame(screenshot: Image.Image, rail_width: int) -> tuple[Image.Image, dict]:
    """Render an iPhone dark-aluminium shell around `screenshot` at hi-res.

    `screenshot` already contains the status bar and Dynamic Island, so this
    draws the rail, black bezel, and side buttons only -- no notch cutout.

    Structure outside in: a dark-aluminium rail (the same METAL_* palette as
    mac_frame's lid/base, the outer ring the eye reads as "metal"), a
    near-black bezel ring inset from it (what actually separates the metal
    from the glass on a real device -- without it the rail reads as a flat
    border rather than a machined edge), then the screen clipped just inside
    that.
    """
    rail_thickness = rail_width * 0.022
    bezel_thickness = rail_width * 0.025
    outer_radius = rail_width * 0.11

    total_inset = rail_thickness + bezel_thickness
    screen_w = rail_width - 2 * total_inset
    screen_h = round(screen_w * screenshot.height / screenshot.width)
    rail_height = round(screen_h + 2 * total_inset)

    # Concentric radius reduction: each inner ring's radius shrinks by
    # roughly the thickness of the ring outside it, so the rail and bezel
    # keep a constant width all the way around the corner arc.
    bezel_radius = max(1.0, outer_radius - rail_thickness)
    screen_radius = max(1.0, bezel_radius - bezel_thickness)

    protrusion = rail_width * 0.014  # how far a button pokes past the rail edge
    into_rail = rail_width * 0.014  # how far it's inset back into the rail
    button_thickness = protrusion + into_rail
    button_outline_w = max(1, round(rail_width * 0.0015))

    shadow_blur = rail_width * 0.05
    margin = round(shadow_blur * 3 + protrusion + rail_width * 0.05)

    canvas_w = rail_width + 2 * margin
    canvas_h = rail_height + 2 * margin

    rail_x0, rail_y0 = float(margin), float(margin)
    rail_x1, rail_y1 = rail_x0 + rail_width, rail_y0 + rail_height

    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    # Same grounding-shadow treatment as the Mac shell (SHADOW_ALPHA) now
    # that the rail is the same dark-aluminium tone -- a dark shape already
    # reads clearly on a white background without a deeper shadow.
    canvas = add_ground_shadow(
        canvas,
        (rail_x0, rail_y0, rail_x1, rail_y1),
        radius=outer_radius,
        blur=shadow_blur,
        y_offset=rail_width * 0.02,
    )

    # --- Side buttons: same metal as the rail, drawn beneath it so they
    # read as protruding only where they poke past its outline. A thin
    # darker outline keeps them legible against a white background at the
    # same small size that would otherwise wash out. ---
    button_layer = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    bd = ImageDraw.Draw(button_layer)

    def side_button(edge_x: float, direction: int, y_center: float, length: float) -> None:
        # direction: -1 pokes left past rail_x0, +1 pokes right past rail_x1.
        near = edge_x - into_rail if direction < 0 else edge_x + into_rail
        far = edge_x + protrusion if direction < 0 else edge_x - protrusion
        x0, x1 = sorted((near, far))
        box = _int_box((x0, y_center - length / 2, x1, y_center + length / 2))
        radius = button_thickness / 2
        bd.rounded_rectangle(box, radius=radius, fill=MAC_LIGHT + (255,))
        bd.rounded_rectangle(box, radius=radius, outline=METAL_MID + (255,), width=button_outline_w)

    # Left: action button, then volume up / down, positioned as percentages
    # of the phone's height to match real hardware.
    side_button(rail_x0, -1, rail_y0 + rail_height * (0.19 + 0.04 / 2), rail_height * 0.04)
    side_button(rail_x0, -1, rail_y0 + rail_height * (0.26 + 0.065 / 2), rail_height * 0.065)
    side_button(rail_x0, -1, rail_y0 + rail_height * (0.34 + 0.065 / 2), rail_height * 0.065)
    # Right: side/power button, longer and positioned lower than the left pair.
    side_button(rail_x1, 1, rail_y0 + rail_height * (0.30 + 0.09 / 2), rail_height * 0.09)

    canvas = Image.alpha_composite(canvas, button_layer)

    # --- Rail: dark-aluminium vertical gradient (brightest at the very
    # top/bottom and along the corner arcs, a darker METAL_MID band through
    # the middle of each long side -- that band is what gives a dark rail
    # real tonal variation instead of reading as a flat plastic slab), with
    # a subtle bright line along the outer edge to catch the light and a
    # slightly darker line along the inner edge where it meets the black
    # bezel. ---
    rail_gradient = vertical_gradient_image(
        rail_width,
        round(rail_height),
        [
            (0.0, RAIL_HIGHLIGHT),
            (0.25, MAC_LIGHT),
            (0.5, METAL_MID),
            (0.75, MAC_LIGHT),
            (1.0, RAIL_HIGHLIGHT),
        ],
    )
    rail_mask = Image.new("L", (canvas_w, canvas_h), 0)
    rmd = ImageDraw.Draw(rail_mask)
    rmd.rounded_rectangle(_int_box((rail_x0, rail_y0, rail_x1, rail_y1)), radius=round(outer_radius), fill=255)

    rail_rgb = Image.new("RGB", (canvas_w, canvas_h), PHONE_BEZEL_COLOR)
    rail_rgb.paste(rail_gradient, (round(rail_x0), round(rail_y0)))
    rail_draw = ImageDraw.Draw(rail_rgb)

    bezel_box = _int_box(
        (rail_x0 + rail_thickness, rail_y0 + rail_thickness, rail_x1 - rail_thickness, rail_y1 - rail_thickness)
    )
    # Both strokes below are centered on a boundary rather than inset from
    # it: the bright outer stroke has its outer half clipped away by
    # rail_mask (leaving a thin rim just inside the true edge), and the dark
    # inner stroke has its inner half covered by the opaque bezel layer
    # drawn next (leaving a thin darker ring right where metal meets glass).
    inner_edge_w = max(SUPERSAMPLE, round(rail_width * 0.004))
    rail_draw.rounded_rectangle(bezel_box, radius=round(bezel_radius), outline=METAL_MID, width=inner_edge_w)

    # Outer edge: a thin contour traced fully inside the mask boundary
    # (unlike the strokes above, not centered on it) so it survives masking
    # at full strength -- this is what keeps the silhouette crisp against
    # GitHub's dark theme, where a dark-aluminium rail alone has little
    # contrast against the page. A brighter catch-light line sits just
    # inside it.
    contour_w = max(SUPERSAMPLE, round(rail_width * 0.003))
    rail_draw.rounded_rectangle(
        _int_box(
            (
                rail_x0 + contour_w / 2,
                rail_y0 + contour_w / 2,
                rail_x1 - contour_w / 2,
                rail_y1 - contour_w / 2,
            )
        ),
        radius=round(outer_radius - contour_w / 2),
        outline=RAIL_CONTOUR,
        width=contour_w,
    )
    highlight_w = max(SUPERSAMPLE, round(rail_width * 0.003))
    highlight_inset = contour_w + highlight_w / 2
    rail_draw.rounded_rectangle(
        _int_box(
            (
                rail_x0 + highlight_inset,
                rail_y0 + highlight_inset,
                rail_x1 - highlight_inset,
                rail_y1 - highlight_inset,
            )
        ),
        radius=round(outer_radius - highlight_inset),
        outline=(251, 250, 247),
        width=highlight_w,
    )

    rail_layer = rail_rgb.convert("RGBA")
    rail_layer.putalpha(rail_mask)
    canvas = Image.alpha_composite(canvas, rail_layer)

    # --- Bezel: near-black ring between the metal rail and the screen --
    # this is what makes the rail read as metal instead of as a border. ---
    bezel_mask = Image.new("L", (canvas_w, canvas_h), 0)
    bzd = ImageDraw.Draw(bezel_mask)
    bzd.rounded_rectangle(bezel_box, radius=round(bezel_radius), fill=255)
    bezel_rgb = Image.new("RGB", (canvas_w, canvas_h), PHONE_BEZEL_COLOR)
    bezel_layer = bezel_rgb.convert("RGBA")
    bezel_layer.putalpha(bezel_mask)
    canvas = Image.alpha_composite(canvas, bezel_layer)

    # --- Screen: black backing, slightly smaller radius than the bezel's,
    # screenshot resized to fit exactly (aspect already matches). ---
    screen_x0 = rail_x0 + total_inset
    screen_y0 = rail_y0 + total_inset
    screen_x1 = screen_x0 + screen_w
    screen_y1 = screen_y0 + screen_h
    screen_layer = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    screen_mask = Image.new("L", (canvas_w, canvas_h), 0)
    smd = ImageDraw.Draw(screen_mask)
    smd.rounded_rectangle(_int_box((screen_x0, screen_y0, screen_x1, screen_y1)), radius=round(screen_radius), fill=255)
    screen_rgb = Image.new("RGB", (canvas_w, canvas_h), SCREEN_BACKING)
    fitted = screenshot.resize((round(screen_w), round(screen_h)), Image.LANCZOS)
    screen_rgb.paste(fitted, (round(screen_x0), round(screen_y0)))
    screen_layer = screen_rgb.convert("RGBA")
    screen_layer.putalpha(screen_mask)
    canvas = Image.alpha_composite(canvas, screen_layer)

    info = {
        "rail_box": (rail_x0, rail_y0, rail_x1, rail_y1),
        "margin": margin,
    }
    return canvas, info


def _paste_sprite(canvas: Image.Image, sprite: Image.Image, pos: tuple[int, int]) -> Image.Image:
    """Alpha-composite `sprite` onto `canvas` at `pos`, blending its own
    (already-baked-in) shadow properly against whatever canvas already
    holds, instead of Image.paste's hard-edged mask behaviour."""
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(sprite, pos, sprite)
    return Image.alpha_composite(canvas, layer)


def build_devices_composite() -> None:
    hero = Image.open(HERO_PATH).convert("RGBA")
    ios_sessions = Image.open(IOS_SESSIONS_PATH).convert("RGBA")

    mac_lid_width_hi = 3200
    mac_img, mac_info = mac_frame(hero, mac_lid_width_hi)

    phone_rail_width_hi = round(mac_lid_width_hi * 0.27)
    phone_img, phone_info = phone_frame(ios_sessions, phone_rail_width_hi)

    canvas_w = mac_img.width + phone_img.width
    canvas_h = mac_img.height + phone_img.height
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    mac_pos = (round(canvas_w * 0.2), round(canvas_h * 0.15))
    canvas = _paste_sprite(canvas, mac_img, mac_pos)

    lid_x0, lid_y0, lid_x1, lid_y1 = mac_info["lid_box"]
    base_x0, base_y0, base_x1, base_y1 = mac_info["base_bottom_box"]
    lid_height = lid_y1 - lid_y0

    # Phone's rail right edge lines up with the Mac base's (wider) right
    # edge, and its top overlaps the lid's lower-right corner so it hangs
    # down well past the base -- per the approved composition sketch.
    target_right = mac_pos[0] + base_x1
    target_top = mac_pos[1] + lid_y0 + lid_height * 0.56

    rail_x0, rail_y0, rail_x1, rail_y1 = phone_info["rail_box"]
    phone_pos = (round(target_right - rail_x1), round(target_top - rail_y0))
    canvas = _paste_sprite(canvas, phone_img, phone_pos)

    crop_box = (
        min(mac_pos[0], phone_pos[0]),
        min(mac_pos[1], phone_pos[1]),
        max(mac_pos[0] + mac_img.width, phone_pos[0] + phone_img.width),
        max(mac_pos[1] + mac_img.height, phone_pos[1] + phone_img.height),
    )
    canvas = canvas.crop(crop_box)

    final_height = round(canvas.height * (DEVICES_FINAL_WIDTH / canvas.width))
    canvas = canvas.resize((DEVICES_FINAL_WIDTH, final_height), Image.LANCZOS)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    canvas.save(DEVICES_OUT_PATH)
    print(f"wrote {DEVICES_OUT_PATH} ({canvas.width}x{canvas.height})")


def build_ios_composite() -> None:
    ios_sessions = Image.open(IOS_SESSIONS_PATH).convert("RGBA")
    ios_terminal = Image.open(IOS_TERMINAL_PATH).convert("RGBA")

    rail_width_hi = 1500
    p1_img, p1_info = phone_frame(ios_sessions, rail_width_hi)
    p2_img, p2_info = phone_frame(ios_terminal, rail_width_hi)

    gap = round(rail_width_hi * 0.16)

    p1_rail_bottom = p1_info["rail_box"][3]
    p2_rail_bottom = p2_info["rail_box"][3]
    common_bottom = max(p1_rail_bottom, p2_rail_bottom)
    p1_y = round(common_bottom - p1_rail_bottom)
    p2_y = round(common_bottom - p2_rail_bottom)

    canvas_w = p1_img.width + gap + p2_img.width
    canvas_h = max(p1_y + p1_img.height, p2_y + p2_img.height)
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    p1_pos = (0, p1_y)
    p2_pos = (p1_img.width + gap, p2_y)
    canvas = _paste_sprite(canvas, p1_img, p1_pos)
    canvas = _paste_sprite(canvas, p2_img, p2_pos)

    final_height = round(canvas.height * (IOS_FINAL_WIDTH / canvas.width))
    canvas = canvas.resize((IOS_FINAL_WIDTH, final_height), Image.LANCZOS)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    canvas.save(IOS_OUT_PATH)
    print(f"wrote {IOS_OUT_PATH} ({canvas.width}x{canvas.height})")


def main() -> None:
    build_devices_composite()
    build_ios_composite()


if __name__ == "__main__":
    main()
