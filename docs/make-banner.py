"""Draws docs/banner.gif: a lo-fi pixel banner, a nozzle printing layer by layer.

Drawn at 284x50 and scaled up 3x in whole pixels, so every pixel stays square.
Black ground, 1-px line art, dithered fills, a 5x5 pixel font, one signal colour.

    python3 docs/make-banner.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

W, H, SCALE = 284, 50, 3
BG, INK, DIM, FAINT, SIGNAL = (0, 0, 0), (244, 241, 234), (107, 104, 98), (42, 41, 39), (255, 107, 26)

FONT = {
    "A": ["01110", "10001", "11111", "10001", "10001"],
    "B": ["11110", "10001", "11110", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "11110"],
    "H": ["10001", "10001", "11111", "10001", "10001"],
    "E": ["11111", "10000", "11110", "10000", "11111"],
    "F": ["11111", "10000", "11110", "10000", "10000"],
    "G": ["01111", "10000", "10011", "10001", "01111"],
    "I": ["111", "010", "010", "010", "111"],
    "K": ["10001", "10010", "11100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001"],
    "O": ["01110", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "11110", "10000", "10000"],
    "R": ["11110", "10001", "11110", "10010", "10001"],
    "S": ["01111", "10000", "01110", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10101", "11011", "10001"],
    "Y": ["10001", "01010", "00100", "00100", "00100"],
    "0": ["01110", "10011", "10101", "11001", "01110"],
    "1": ["010", "110", "010", "010", "111"],
    "2": ["11110", "00001", "01110", "10000", "11111"],
    "3": ["11110", "00001", "00110", "00001", "11110"],
    "4": ["10010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "11110"],
    "6": ["01110", "10000", "11110", "10001", "01110"],
    "7": ["11111", "00010", "00100", "01000", "01000"],
    "8": ["01110", "10001", "01110", "10001", "01110"],
    "9": ["01110", "10001", "01111", "00001", "01110"],
    "-": ["000", "000", "111", "000", "000"],
    "%": ["11001", "11010", "00100", "01011", "10011"],
    " ": ["00", "00", "00", "00", "00"],
}

BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]


def text(d, x, y, s, color, size=1):
    for ch in s:
        glyph = FONT[ch]
        for j, row in enumerate(glyph):
            for i, bit in enumerate(row):
                if bit == "1":
                    d.rectangle([x + i * size, y + j * size, x + i * size + size - 1, y + j * size + size - 1], fill=color)
        x += (len(glyph[0]) + 1) * size
    return x


def dither(d, x, y, w, h, level, color):
    t = level * 16
    for j in range(h):
        for i in range(w):
            if BAYER[((y + j) & 3) * 4 + ((x + i) & 3)] < t:
                d.point((x + i, y + j), fill=color)


# The print: one width per layer, bottom up. A little vase.
LAYERS = [30, 30, 28, 24, 22, 22, 24, 28, 30, 26]
LAYER_H = 2
BED_Y = 44
CX = 36  # centre of the bed
STEPS = 8  # frames per layer


def frame(n):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    finished = n >= len(LAYERS) * STEPS
    layer, step = (len(LAYERS), 0) if finished else divmod(n, STEPS)
    progress = (layer * STEPS + step) / (len(LAYERS) * STEPS)

    # Frame of the printer: posts, top rail, bed.
    d.line([(6, 6), (6, BED_Y)], fill=DIM)
    d.line([(66, 6), (66, BED_Y)], fill=DIM)
    d.line([(6, 6), (66, 6)], fill=DIM)
    d.line([(4, BED_Y + 1), (68, BED_Y + 1)], fill=INK)
    dither(d, 7, BED_Y + 2, 59, 2, 0.5, FAINT)

    # Finished layers, dithered.
    for i in range(layer):
        w = LAYERS[i]
        dither(d, CX - w // 2, BED_Y - (i + 1) * LAYER_H, w, LAYER_H, 0.6, INK)

    if finished:
        # Parked out of the way, nozzle cold.
        y, nozzle_x = 22, 14
    else:
        # The layer being printed, in the signal colour, up to the nozzle.
        w = LAYERS[layer]
        left = CX - w // 2
        going_right = layer % 2 == 0
        done = round(w * (step + 1) / STEPS)
        y = BED_Y - (layer + 1) * LAYER_H
        if going_right:
            d.rectangle([left, y, left + done - 1, y + LAYER_H - 1], fill=SIGNAL)
            nozzle_x = left + done - 1
        else:
            d.rectangle([left + w - done, y, left + w - 1, y + LAYER_H - 1], fill=SIGNAL)
            nozzle_x = left + w - done

    # Gantry rail and carriage, riding just above the current layer.
    rail_y = y - 9
    d.line([(7, rail_y), (65, rail_y)], fill=DIM)
    d.rectangle([nozzle_x - 4, rail_y - 3, nozzle_x + 4, rail_y + 3], outline=INK, fill=BG)
    d.line([(nozzle_x - 2, rail_y + 4), (nozzle_x + 2, rail_y + 4)], fill=INK)
    d.line([(nozzle_x - 1, rail_y + 5), (nozzle_x + 1, rail_y + 5)], fill=INK)
    if not finished:
        d.point((nozzle_x, rail_y + 6), fill=SIGNAL)
        d.line([(nozzle_x, rail_y + 7), (nozzle_x, y - 1)], fill=SIGNAL)

    # Name, tagline and a live status line.
    text(d, 80, 9, "BAMBU-SWIFT", INK, size=2)
    text(d, 80, 25, "PRINTER STATUS OVER YOUR NETWORK", DIM)
    if finished:
        d.rectangle([80, 37, 82, 39], fill=INK)
        text(d, 86, 36, "FINISHED", INK)
    else:
        if n % 6 < 4:  # the dot blinks while printing
            d.rectangle([80, 37, 82, 39], fill=SIGNAL)
        text(d, 86, 36, f"PRINTING {round(progress * 100)}%", SIGNAL)
    return img.resize((W * SCALE, H * SCALE), Image.NEAREST)


# Print, then hold the finished print for a moment before starting again.
frames = [frame(n) for n in range(len(LAYERS) * STEPS + 14)]

out = Path(__file__).with_name("banner.gif")
frames[0].save(out, save_all=True, append_images=frames[1:], duration=90, loop=0, optimize=True, disposal=1)
print(out, len(frames), "frames")
