#!/usr/bin/env python3
"""Fail if any article in editions/latest repeats a story from an earlier archived edition.
Matches on URL or on normalized headline. Run from repo root: python3 -I tools/dedupe_check.py"""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
ed = root / "editions"
latest = json.loads((ed / "latest" / "index.json").read_text())
today = latest["date"]


def norm(h):
    return re.sub(r"[^a-z0-9 ]", "", h.lower()).strip()


seen_urls, seen_heads = {}, {}
for d in sorted((ed / "archive").glob("*/")):
    if d.name >= today:
        continue
    for f in (d / "a").glob("*.json"):
        a = json.loads(f.read_text())
        seen_urls[a.get("url", "")] = d.name
        seen_heads[norm(a.get("headline", ""))] = d.name

errors = []
for f in sorted((ed / "latest" / "a").glob("*.json")):
    a = json.loads(f.read_text())
    if a.get("url") in seen_urls:
        errors.append(f"{a['id']}: URL already published on {seen_urls[a['url']]}")
    if norm(a.get("headline", "")) in seen_heads:
        errors.append(f"{a['id']}: headline already published on {seen_heads[norm(a['headline'])]}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("OK: no repeated stories")
