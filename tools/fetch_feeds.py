#!/usr/bin/env python3
"""Pull RSS feeds listed in config.json and write sources/today.json. Standard library only."""
import json, sys, urllib.request, xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
import re, html

root = Path(__file__).resolve().parent.parent
cfg = json.loads((root / "config.json").read_text())
now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=60)
out, status = [], {}


def clean(s):
    s = html.unescape(re.sub(r"<[^>]+>", " ", s or ""))
    return re.sub(r"\s+", " ", s).strip()[:600]


def tag(el, *names):
    for name in names:
        for c in el:
            if c.tag.split("}")[-1] == name:
                return c
    return None


for f in cfg.get("feeds", []):
    try:
        req = urllib.request.Request(f["url"], headers={"User-Agent": "Mozilla/5.0 (x4-daily-paper feed fetcher)"})
        data = urllib.request.urlopen(req, timeout=30).read()
        rootel = ET.fromstring(data)
        items = [e for e in rootel.iter() if e.tag.split("}")[-1] in ("item", "entry")]
        kept = 0
        for it in items:
            title = clean(getattr(tag(it, "title"), "text", ""))
            le = tag(it, "link")
            link = (le.text or le.get("href") or "").strip() if le is not None else ""
            de = tag(it, "pubDate", "published", "updated")
            try:
                d = parsedate_to_datetime(de.text) if de is not None and "," in (de.text or "") else datetime.fromisoformat(de.text.replace("Z", "+00:00"))
                if d.tzinfo is None:
                    d = d.replace(tzinfo=timezone.utc)
            except Exception:
                continue
            if d < cutoff or not title or not link:
                continue
            se = tag(it, "description", "summary")
            out.append({"section": f["section"], "source": f["name"], "title": title, "url": link,
                        "published": d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
                        "summary": clean(se.text if se is not None else "")})
            kept += 1
        status[f["name"]] = f"ok {kept}"
    except Exception as e:
        status[f["name"]] = f"failed {type(e).__name__}"
out.sort(key=lambda x: x["published"], reverse=True)
(root / "sources").mkdir(exist_ok=True)
(root / "sources" / "today.json").write_text(json.dumps({"generated_at": now.strftime("%Y-%m-%dT%H:%MZ"), "feed_status": status, "items": out}, indent=1))
print(json.dumps(status, indent=1), len(out), "items")
