"""Slice a full-page screenshot into viewport-height bands for vision review.
Usage: python3 slice.py full.png outprefix [band_height]"""
import sys
from PIL import Image

src, prefix = sys.argv[1], sys.argv[2]
band = int(sys.argv[3]) if len(sys.argv) > 3 else 1100
im = Image.open(src)
w, h = im.size
i = 0
for top in range(0, h, band):
    im.crop((0, top, w, min(h, top + band))).save(f"{prefix}-{i:02d}.png")
    i += 1
print(f"{i} bands of {w}x{band} from {w}x{h}")
