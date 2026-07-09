"""OAK CLI: tag images from the command line.

Usage:
    python oak_tagger.py IMAGE [IMAGE ...] [--top N] [--threshold T] [--vocab FILE]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

from oak_core import DEFAULT_VOCAB, Tagger


def main() -> None:
    ap = argparse.ArgumentParser(description="OAK tagger (SigLIP 2 zero-shot)")
    ap.add_argument("images", nargs="+", type=Path)
    ap.add_argument("--top", type=int, default=10, help="max keywords per image")
    ap.add_argument("--threshold", type=float, default=0.0005, help="absolute floor")
    ap.add_argument("--rel", type=float, default=0.2,
                    help="keep keywords within this fraction of the top score")
    ap.add_argument("--vocab", type=Path, default=DEFAULT_VOCAB)
    args = ap.parse_args()

    tagger = Tagger(vocab_path=args.vocab)
    for img_path in args.images:
        try:
            image = Image.open(img_path)
        except OSError as e:
            print(f"\n{img_path}: cannot open ({e})", file=sys.stderr)
            continue
        results = tagger.tag(image, top=args.top, threshold=args.threshold,
                             rel=args.rel)
        print(f"\n== {img_path} ==")
        if not results:
            print("  (no keywords above threshold)")
        for r in results:
            print(f"  {r['confidence']:6.1%}  {r['keyword']}")


if __name__ == "__main__":
    main()
