"""Where a recording moves: the mean difference of each frame from the one
before, so the frames of a transition can be found and looked at one by one.

    python3 tools/motion.py /tmp/search-ios-rec/NAME [threshold]

Prints the runs of moving frames, and the single-frame jumps inside them
(a frame that differs far more from its neighbour than the frames around
it — the shape of something appearing or going all at once).
"""
import glob, sys
from PIL import Image, ImageChops, ImageStat

root = sys.argv[1]
threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.4
files = sorted(glob.glob(root + "/frames/*.png"))
small = [Image.open(f).convert("L").resize((201, 437)) for f in files]
diffs = [0.0] + [ImageStat.Stat(ImageChops.difference(a, b)).mean[0] for a, b in zip(small, small[1:])]

runs, start = [], None
for i, d in enumerate(diffs):
    if d > threshold and start is None:
        start = i
    if d <= threshold and start is not None:
        runs.append((start, i - 1)); start = None
if start is not None:
    runs.append((start, len(diffs) - 1))

for a, b in runs:
    seg = diffs[a:b + 1]
    peak = max(seg)
    print(f"frames {a + 1}-{b + 1}: {b - a + 1} moving, peak {peak:.1f} at {a + seg.index(peak) + 1}")
    for k in range(a, b + 1):
        around = [diffs[j] for j in (k - 2, k - 1, k + 1, k + 2) if 0 <= j < len(diffs) and a <= j <= b]
        typical = sorted(around)[len(around) // 2] if around else 0
        if diffs[k] > 4 and diffs[k] > 3 * max(typical, 0.5):
            print(f"   jump at frame {k + 1}: {diffs[k]:.1f} (around {typical:.1f})")
