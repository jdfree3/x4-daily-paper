#!/usr/bin/env python3
"""Pull RSS feeds from config.json, resolve Google News links, filter Idaho feeds by keyword,
fetch article text, and write sources/today.json (index) and sources/articles/<section>.json (text).
Run from repo root. Uses trafilatura if installed, else a plain HTML paragraph extractor."""
import base64, html, json, re, sys, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

try:
    import trafilatura
except Exception:
    trafilatura = None

root = Path(__file__).resolve().parent.parent
cfg = json.loads((root / "config.json").read_text())
af = cfg.get("article_fetch", {})
PER_SECTION, PER_SOURCE = af.get("per_section", 24), af.get("per_source", 8)
MAX_CHARS, DELAY = af.get("max_chars", 3000), af.get("delay_seconds", 0.6)
KEYWORDS = [k.lower() for k in cfg.get("idaho_keywords", [])]
now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=60)
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"}


def http(url, data=None, headers=None, timeout=30):
    h = dict(UA)
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h)
    return urllib.request.urlopen(req, timeout=timeout)


def clean(s, n=600):
    s = html.unescape(re.sub(r"<[^>]+>", " ", s or ""))
    return re.sub(r"\s+", " ", s).strip()[:n]


def tag(el, *names):
    for name in names:
        for c in el:
            if c.tag.split("}")[-1] == name:
                return c
    return None


def strip_tracking(u):
    if "news.google.com" in u:
        return u
    p = urllib.parse.urlsplit(u)
    q = [(k, v) for k, v in urllib.parse.parse_qsl(p.query) if not (k.startswith("utm_") or k in ("at_medium", "at_campaign", "cmpid", "ocid", "taid"))]
    return urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, urllib.parse.urlencode(q), ""))


def resolve_google(url):
    """Best effort: turn a news.google.com/rss/articles link into the outlet URL. Returns None on failure."""
    try:
        gid = url.split("/articles/")[1].split("?")[0]
        b = base64.urlsafe_b64decode(gid + "=" * (-len(gid) % 4))
        if b.startswith(b"\x08\x13\x22"):
            b = b[3:]
        if b.endswith(b"\xd2\x01\x00"):
            b = b[:-3]
        ln = b[0]
        if ln >= 0x80:
            ln = (ln & 0x7F) | (b[1] << 7)
            b = b[2:]
        else:
            b = b[1:]
        s = b[:ln].decode("utf-8", "ignore")
        if s.startswith("http"):
            return s
    except Exception:
        pass
    try:
        page = http(f"https://news.google.com/articles/{gid}?hl=en-US&gl=US&ceid=US:en").read().decode("utf-8", "ignore")
        sg = re.search(r'data-n-a-sg="([^"]+)"', page).group(1)
        ts = re.search(r'data-n-a-ts="([^"]+)"', page).group(1)
        inner = ('["garturlreq",[["X","X",["X","X"],null,null,1,1,"US:en",null,1,null,null,null,null,null,0,1],"X","X",1,[1,1,1],1,1,null,0,0,null,0],'
                 f'"{gid}",{ts},"{sg}"]')
        body = urllib.parse.urlencode({"f.req": json.dumps([[["Fbv4je", inner]]])}).encode()
        r = http("https://news.google.com/_/DotsSplashUi/data/batchexecute", data=body,
                 headers={"Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"}).read().decode("utf-8", "ignore")
        parsed = json.loads(r.split("\n\n")[1])
        out = json.loads(parsed[0][2])[1]
        return out if str(out).startswith("http") else None
    except Exception:
        return None


def extract(page_html):
    if trafilatura:
        try:
            t = trafilatura.extract(page_html, include_comments=False, include_tables=False)
            if t and len(t) > 200:
                return t
        except Exception:
            pass
    h = re.sub(r"(?is)<(script|style|noscript|nav|footer|header)[^>]*>.*?</\1>", " ", page_html)
    paras = [clean(p, 5000) for p in re.findall(r"(?is)<p[^>]*>(.*?)</p>", h)]
    return "\n".join(p for p in paras if len(p) > 60)


def get_text(url):
    try:
        raw = http(url, timeout=25).read(2_000_000).decode("utf-8", "ignore")
    except Exception as e:
        return None, f"fetch failed {type(e).__name__}"
    t = extract(raw)
    if not t or len(t) < 200:
        return None, "no text (paywall or blocked)"
    return t[:MAX_CHARS], "ok"


# archive URLs, so repeated stories are not fetched
seen = set()
for f in (root / "editions" / "archive").glob("*/a/*.json"):
    try:
        seen.add(json.loads(f.read_text()).get("url"))
    except Exception:
        pass

items, status = [], {}
for f in cfg.get("feeds", []):
    try:
        rootel = ET.fromstring(http(f["url"]).read())
        kept = 0
        for it in [e for e in rootel.iter() if e.tag.split("}")[-1] in ("item", "entry")]:
            title = clean(getattr(tag(it, "title"), "text", ""), 300)
            le = tag(it, "link")
            link = ((le.text or le.get("href") or "") if le is not None else "").strip()
            de = tag(it, "pubDate", "published", "updated")
            try:
                d = parsedate_to_datetime(de.text) if "," in (de.text or "") else datetime.fromisoformat(de.text.replace("Z", "+00:00"))
                if d.tzinfo is None:
                    d = d.replace(tzinfo=timezone.utc)
            except Exception:
                continue
            if d < cutoff or not title or not link:
                continue
            se = tag(it, "description", "summary")
            summary = clean(se.text if se is not None else "")
            if f.get("keyword_filter") == "idaho":
                blob = (title + " " + summary).lower()
                if not any(k in blob for k in KEYWORDS):
                    continue
            items.append({"section": f["section"], "source": f["name"], "title": title, "url": strip_tracking(link),
                          "published": d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"), "summary": summary})
            kept += 1
        status[f["name"]] = f"ok {kept}"
    except Exception as e:
        status[f["name"]] = f"failed {type(e).__name__}"

items.sort(key=lambda x: x["published"], reverse=True)

# choose items to fetch: newest first, capped per source, per section
chosen, per_sec, per_src = [], {}, {}
for it in items:
    s, k = it["section"], (it["section"], it["source"])
    if it["url"] in seen or per_sec.get(s, 0) >= PER_SECTION or per_src.get(k, 0) >= PER_SOURCE:
        continue
    chosen.append(it)
    per_sec[s] = per_sec.get(s, 0) + 1
    per_src[k] = per_src.get(k, 0) + 1

adir = root / "sources" / "articles"
adir.mkdir(parents=True, exist_ok=True)
for old in adir.glob("*.json"):
    old.unlink()
bysec = {}
for it in chosen:
    if "news.google.com" in it["url"]:
        real = resolve_google(it["url"])
        time.sleep(DELAY)
        if real:
            it["feed_url"], it["url"] = it["url"], strip_tracking(real)
            it["url_resolved"] = True
        else:
            it["url_resolved"] = False
            it["text_status"] = "google link not resolved"
            bysec.setdefault(it["section"], []).append(it)
            continue
        if it["url"] in seen:
            continue
    text, st = get_text(it["url"])
    time.sleep(DELAY)
    it["text_status"] = st
    if text:
        it["text"] = text
    bysec.setdefault(it["section"], []).append(it)

for s, lst in bysec.items():
    (adir / f"{s}.json").write_text(json.dumps(lst, indent=1))
index = [{k: v for k, v in it.items() if k != "text"} | {"has_text": it in sum(bysec.values(), []) and "text" in it} for it in items]
(root / "sources" / "today.json").write_text(json.dumps({"generated_at": now.strftime("%Y-%m-%dT%H:%MZ"), "feed_status": status, "items": index}, indent=1))
ok = sum(1 for l in bysec.values() for i in l if "text" in i)
print(json.dumps(status, indent=1))
print(len(items), "items,", len(chosen), "chosen,", ok, "with text")
