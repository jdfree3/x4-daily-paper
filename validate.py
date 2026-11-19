#!/usr/bin/env python3
"""Validate editions/latest against config.json. Exit 1 on any error."""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
cfg = json.loads((root / "config.json").read_text())
lim = cfg["limits"]
ed = root / "editions" / "latest"
errors = []


def ascii_ok(label, s):
    try:
        s.encode("ascii")
    except UnicodeEncodeError:
        bad = sorted({c for c in s if ord(c) > 127})
        errors.append(f"{label}: non ASCII characters {bad}")


idx_path = ed / "index.json"
if not idx_path.exists():
    sys.exit("missing editions/latest/index.json")
idx = json.loads(idx_path.read_text())

for key in ("paper", "date", "weekday", "generated_at", "sections"):
    if key not in idx:
        errors.append(f"index.json missing {key}")

seen = set()
total = idx_path.stat().st_size
for sec in idx.get("sections", []):
    want = next((s for s in cfg["sections"] if s["id"] == sec.get("id")), None)
    if not want:
        errors.append(f"unknown section {sec.get('id')}")
        continue
    arts = sec.get("articles", [])
    if len(arts) > want["articles"]:
        errors.append(f"section {sec['id']} has {len(arts)} articles, max {want['articles']}")
    for a in arts:
        aid = a.get("id", "?")
        if aid in seen:
            errors.append(f"duplicate id {aid}")
        seen.add(aid)
        if len(a.get("headline", "")) > lim["headline_chars"]:
            errors.append(f"{aid}: headline too long")
        if len(a.get("summary", "")) > lim["summary_chars"]:
            errors.append(f"{aid}: summary too long")
        for f in ("headline", "summary", "source"):
            ascii_ok(f"{aid}.{f}", a.get(f, ""))
        p = ed / "a" / f"{aid}.json"
        if not p.exists():
            errors.append(f"{aid}: missing article file")
            continue
        total += p.stat().st_size
        art = json.loads(p.read_text())
        pages = art.get("pages", [])
        if not pages:
            errors.append(f"{aid}: no pages")
        if len(pages) > lim["max_pages_per_article"]:
            errors.append(f"{aid}: {len(pages)} pages, max {lim['max_pages_per_article']}")
        if a.get("pages") != len(pages):
            errors.append(f"{aid}: index says {a.get('pages')} pages, file has {len(pages)}")
        for i, pg in enumerate(pages, 1):
            if len(pg) > lim["page_chars"]:
                errors.append(f"{aid} page {i}: {len(pg)} chars, max {lim['page_chars']}")
            ascii_ok(f"{aid} page {i}", pg)
        if not str(art.get("url", "")).startswith("http"):
            errors.append(f"{aid}: missing url")

extra = {p.stem for p in (ed / "a").glob("*.json")} - seen
if extra:
    errors.append(f"orphan article files: {sorted(extra)}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"OK: {len(seen)} articles, {total} bytes")
