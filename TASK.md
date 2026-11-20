# Daily edition task

You are the editor of a small daily newspaper that is read on an Xteink X4 Pro e-ink reader (480x800, plain text, tiny memory). Follow these steps each morning. Edit this file or config.json to change how the paper works; the scheduled task just says "read TASK.md and follow it".

## Sourcing rules (learned from testing)

- Get today's date and weekday first (run `date` or use a current time tool) and use it as the edition date.
- Web search often mixes in stories from earlier years or weeks. Put the full date in queries (for example "Boise news November 19 2026") and prefer the Preferred sources. Search each section separately.
- Only use a story if a page or snippet shows a publication date within the last 48 hours of the edition date. Open the page with WebFetch when the date is unclear. Skip anything you cannot date.
- WebFetch asks the owner for permission once per website, and nobody is watching a scheduled run, so an unapproved site would stall it. Only WebFetch pages on the domains listed in config.json under fetch_domains. For every other site, use WebSearch snippets only and never fetch it. To allow a new site, the owner approves it once and adds it to fetch_domains.
- RSS feeds may be blocked by the fetch tool. Do not rely on them; fall back to search result pages and news site section pages that appear in search results.
- Never invent details. Write only what the sources say. If you cannot confirm a fact in two places or in the primary source, leave it out.
- If a section ends up with fewer articles than requested, ship fewer. Add a line to editions/latest/notes.txt saying which sections were thin and why, so the owner can tune config.json.

## Steps

1. Read config.json. It defines the paper name, sections, how many articles each section gets, preferred sources, style, and size limits.
2. For each section, search the web for today's news that fits the section focus. Prefer the listed sources. Use several searches per section. Open the best articles with WebFetch when snippets are too thin. Only use stories from the last 24 to 48 hours.
3. Pick the requested number of articles per section. Avoid duplicates across sections and avoid anything under "avoid".
4. Write each article in your own words in the configured style. Do not copy sentences from the source. Never quote more than a short phrase. Always name the source and keep the URL.
5. Build the edition files exactly as described in "Format" below. Set "url_verified": true on an article only if you opened its URL or saw that exact URL in a search result. Otherwise set it to false.
6. Write the briefing last, after every article is final. It is a short summary of the day (see config.json "briefing") that appears at the top of the front page as "index.json.briefing". Use only facts from the day's articles, do not add anything new, and keep it under limits.briefing_chars characters. Also give every section a "brief": one or two very short sentences (at most limits.section_brief_chars characters) covering that section's top stories, drawn only from the section's articles. The reader app shows it under the section name on the front page.
7. Run `pip install --break-system-packages segno` and then `python3 -I tools/make_qr.py` from the repo root. It adds a QR code grid to every article with url_verified true. Articles whose URL is unverified or too long get no QR code.
8. Run `python3 -I validate.py` from the repo root. Fix every error it reports.
9. Replace editions/latest with the new edition, copy it to editions/archive/YYYY-MM-DD, then run `python3 -I tools/make_archive_index.py`. It keeps the 7 newest archive folders, deletes older ones, and writes editions/archive.json, the list the reader app uses to offer past editions with each edition's briefing as its summary. Commit with message "Edition YYYY-MM-DD", and push to the default branch.
10. If a section has too little news, include fewer articles rather than padding. If everything fails, do not push a broken edition; leave the previous one in place.

## Format

All text must be plain ASCII. Replace curly quotes with straight quotes, em and en dashes with a plain hyphen or a comma, ellipsis with three periods, and strip emoji and accents where needed (the device font may not have those glyphs).

### editions/latest/index.json

```json
{
  "paper": "The Godfrey Gazette",
  "date": "2026-11-19",
  "weekday": "Thursday",
  "generated_at": "2026-11-19T13:05:00Z",
  "briefing": "Four to six short sentences summarizing the day, plain ASCII.",
  "sections": [
    {
      "id": "world",
      "name": "World and US",
      "brief": "One or two very short sentences on this section's top stories.",
      "articles": [
        {
          "id": "world-1",
          "headline": "Short headline under the limit",
          "source": "Associated Press",
          "summary": "One line teaser under the limit",
          "pages": 2
        }
      ]
    }
  ]
}
```

### editions/archive.json

Written by tools/make_archive_index.py, never by hand. Newest first, at most 7 entries: `{"editions": [{"date": "2026-11-19", "weekday": "Thursday", "briefing": "...", "stories": 14}]}`. Edition files for a date live under editions/archive/<date>/ with the same index.json and a/ layout as editions/latest.

### editions/latest/a/<article id>.json

```json
{
  "id": "world-1",
  "headline": "Same headline",
  "source": "Associated Press",
  "url": "https://example.com/story",
  "published": "2026-11-19",
  "url_verified": true,
  "qr": {"n": 37, "rows": ["0101...", "..."]},
  "pages": [
    "First page of text, at most page_chars characters, broken at a sentence end.",
    "Second page..."
  ]
}
```

The "qr" key is added by tools/make_qr.py, never by hand: n is the grid size and rows is n strings of n characters, 1 for a black square and 0 for white. The device draws it with a four square white border.

Rules: pages are split at sentence boundaries, never mid word, at most limits.page_chars characters each and limits.max_pages_per_article pages. The first page starts with the lead. The last page ends with a short line starting "Source: " and the outlet name.

## Tweaking ideas

- Change section focus or counts in config.json.
- Add weather, a daily puzzle, or a quote of the day as an extra section.
