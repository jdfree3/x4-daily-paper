#!/usr/bin/env python3
"""Keep the newest KEEP archive editions and write editions/archive.json (newest first).

The reader app reads archive.json to list editions; each entry carries that edition's briefing so the
app can show it as the summary when an edition is selected.
"""
import json
import shutil
from pathlib import Path

KEEP = 7
root = Path(__file__).resolve().parent.parent
arch = root / "editions" / "archive"
dates = sorted((d.name for d in arch.iterdir() if d.is_dir() and (d / "index.json").exists()), reverse=True)
for old in dates[KEEP:]:
    shutil.rmtree(arch / old)
entries = []
for name in dates[:KEEP]:
    idx = json.loads((arch / name / "index.json").read_text())
    entries.append({
        "date": idx["date"],
        "weekday": idx.get("weekday", ""),
        "briefing": idx.get("briefing", ""),
        "stories": sum(len(s["articles"]) for s in idx["sections"]),
    })
(root / "editions" / "archive.json").write_text(json.dumps({"editions": entries}, ensure_ascii=True))
print(f"archive.json: {len(entries)} editions, removed {max(0, len(dates) - KEEP)}")
