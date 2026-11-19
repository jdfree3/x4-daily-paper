#!/usr/bin/env python3
"""Render the word as a bold serif JPEG for the device (it only has 3 small system fonts).

Usage: python3 wotd/tools/make_word_image.py wotd/latest/index.json
Reads "word" from the entry, writes word.jpg next to it, and records word_img {file, w, h}.
The image is at most 328 px wide (the text column) and as large as fits, up to 58 px type.
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, '..', 'fonts', 'DejaVuSerif-Bold.ttf')
MAX_W, MAX_PX, MIN_PX = 328, 58, 30


def render(word, path):
    px = MAX_PX
    while True:
        font = ImageFont.truetype(FONT, px)
        l, t, r, b = font.getbbox(word)
        if r - l <= MAX_W or px <= MIN_PX:
            break
        px -= 1
    # a fixed-height strip based on font metrics so ascenders and descenders always fit
    asc, desc = font.getmetrics()
    w, h = min(MAX_W, r - l + 4), asc + desc + 4
    im = Image.new('L', (w, h), 255)
    ImageDraw.Draw(im).text((2 - l, 2), word, font=font, fill=0)
    im.save(path, quality=95)
    return w, h, px


def main():
    entry = sys.argv[1]
    d = json.load(open(entry))
    out = os.path.join(os.path.dirname(entry), 'word.jpg')
    w, h, px = render(d['word'], out)
    d['word_img'] = {'file': 'word.jpg', 'w': w, 'h': h}
    json.dump(d, open(entry, 'w'), indent=1)
    print('word.jpg %dx%d at %dpx' % (w, h, px))


if __name__ == '__main__':
    main()
