#!/usr/bin/env python3
"""Add a QR grid to every article in editions/latest/a that has a URL, verified or not."""
import json
from pathlib import Path

import segno

MAX_N = 49  # version 8; longer links make a grid that is too dense for the screen
root = Path(__file__).resolve().parent.parent
added = skipped = 0
for p in sorted((root / "editions" / "latest" / "a").glob("*.json")):
    art = json.loads(p.read_text())
    art.pop("qr", None)
    if str(art.get("url", "")).startswith("http"):
        q = segno.make(art["url"], error="l", micro=False, boost_error=False)
        n = len(q.matrix)
        if n <= MAX_N:
            art["qr"] = {"n": n, "rows": ["".join("1" if m else "0" for m in row) for row in q.matrix]}
            added += 1
        else:
            skipped += 1
    else:
        skipped += 1
    p.write_text(json.dumps(art, ensure_ascii=True))
print(f"qr added: {added}, skipped: {skipped}")
