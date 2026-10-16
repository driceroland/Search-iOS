"""A strip of frames from a recording, numbered, to look at a transition one
frame at a time.

    python3 tools/strip.py /tmp/search-ios-rec/NAME FIRST LAST [out.png] [width]
"""
import sys
from PIL import Image, ImageDraw

root, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = sys.argv[4] if len(sys.argv) > 4 else f"{root}/strip-{first}-{last}.png"
width = int(sys.argv[5]) if len(sys.argv) > 5 else 160
frames = []
for n in range(first, last + 1):
    im = Image.open(f"{root}/frames/{n:03d}.png").convert("RGB")
    im = im.resize((width, int(im.height * width / im.width)))
    ImageDraw.Draw(im).rectangle((0, 0, 34, 16), fill="white")
    ImageDraw.Draw(im).text((3, 2), str(n), fill="red")
    frames.append(im)
per = 10
rows = [frames[i:i + per] for i in range(0, len(frames), per)]
sheet = Image.new("RGB", (per * (width + 4), len(rows) * (frames[0].height + 4)), "black")
for r, row in enumerate(rows):
    for c, im in enumerate(row):
        sheet.paste(im, (c * (width + 4), r * (frames[0].height + 4)))
sheet.save(out)
print(out)
