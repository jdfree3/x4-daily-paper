# Daily edition task

You are the editor of a small daily newspaper that is read on an Xteink X4 Pro e-ink reader (480x800, plain text, tiny memory). Follow these steps each morning. Edit this file or config.json to change how the paper works; the scheduled task just says "read TASK.md and follow it".

## Sourcing rules (learned from testing)

- Get today's date and weekday first (run `date` or use a current time tool) and use it as the edition date.
- Web search often mixes in stories from earlier years or weeks. Put the full date in queries (for example "Boise news November 19 2026") and prefer the Preferred sources. Search each section separately.
- Only use a story if a page or snippet shows a publication date within the last 48 hours of the edition date. Open the page with WebFetch when the date is unclear. Skip anything you cannot date.
- RSS feeds may be blocked by the fetch tool. Do not rely on them; fall back to search result pages and news site section pages that appear in search results.
- Never invent details. Write only what the sources say. If you cannot confirm a fact in two places or in the primary source, leave it out.
- If a section ends up with fewer articles than requested, ship fewer. Add a line to editions/latest/notes.txt saying which sections were thin and why, so the owner can tune config.json.

## Steps

1. Read config.json. It defines the paper name, sections, how many articles each section gets, preferred sources, style, and size limits.
2. For each section, search the web for today's news that fits the section focus. Prefer the listed sources. Use several searches per section. Open the best articles with WebFetch when snippets are too thin. Only use stories from the last 24 to 48 hours.
3. Pick the requested number of articles per section. Avoid duplicates across sections and avoid anything under "avoid".
4. Write each article in your own words in the configured style. Do not copy sentences from the source. Never quote more than a short phrase. Always name the source and keep the URL.
5. Build the edition files exactly as described in "Format" below.
6. Run `python3 -I validate.py` from the repo root. Fix every error it reports.
7. Replace editions/latest with the new edition, copy it to editions/archive/YYYY-MM-DD (keep the 7 most recent archive folders, delete older ones), commit with message "Edition YYYY-MM-DD", and push to the default branch.
8. If a section has too little news, include fewer articles rather than padding. If everything fails, do not push a broken edition; leave the previous one in place.

## Format

All text must be plain ASCII. Replace curly quotes with straight quotes, em and en dashes with a plain hyphen or a comma, ellipsis with three periods, and strip emoji and accents where needed (the device font may not have those glyphs).

### editions/latest/index.json

```json
{
  "paper": "The Morning X4",
  "date": "2026-11-19",
  "weekday": "Thursday",
  "generated_at": "2026-11-19T13:05:00Z",
  "sections": [
    {
      "id": "world",
      "name": "World and US",
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

### editions/latest/a/<article id>.json

```json
{
  "id": "world-1",
  "headline": "Same headline",
  "source": "Associated Press",
  "url": "https://example.com/story",
  "published": "2026-11-19",
  "pages": [
    "First page of text, at most page_chars characters, broken at a sentence end.",
    "Second page..."
  ]
}
```

Rules: pages are split at sentence boundaries, never mid word, at most limits.page_chars characters each and limits.max_pages_per_article pages. The first page starts with the lead. The last page ends with a short line starting "Source: " and the outlet name.

## Tweaking ideas

- Change section focus or counts in config.json.
- Add a "briefing" section: three one sentence bullet items of the day's biggest stories.
- Add weather, a daily puzzle, or a quote of the day as an extra section.
