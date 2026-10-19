"""Pixel diff two images: prints sizes and the differing bbox (None = identical).
Usage: python3 imgdiff.py a.png b.png"""
import sys
from PIL import Image, ImageChops

a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
print(a.size, b.size, "diff bbox:", ImageChops.difference(a, b).getbbox() if a.size == b.size else "size differs")
