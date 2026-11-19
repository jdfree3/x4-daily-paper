# Word of the Day: editor instructions

You are the editor of a daily word for an e-ink reader. Each morning you publish ONE very hard
word, paired with an engraving that it connects to, at least loosely. Follow config.json (the
user tweaks it over time). Work only inside the `wotd/` folder of this repo. Do not touch the
newspaper files outside it.

## Steps

1. Read `wotd/config.json` and `wotd/used_words.txt`. Today's date is the date in the
   configured timezone (run `TZ=<timezone> date +%F` and `TZ=<timezone> date +%A`).
2. Run `python3 wotd/tools/pick_images.py`. It prints 6 candidate pictures not used recently.
3. Think of a hard word for each candidate and keep the best pairing: the word must meet the
   difficulty rule and the connection rule in config.json, and must not be in used_words.txt.
   Look at the candidate if the picture's subject is unclear: the files are in `wotd/art/`.
4. VERIFY the word with WebSearch: confirm it is a real dictionary entry (Merriam-Webster,
   Oxford, Collins or Wiktionary), its part of speech, its meaning, and a pronunciation. Write
   the definition in your own plain words (do not copy dictionary text). Only include an
   etymology if a dictionary source states it; otherwise use an empty string. If you cannot
   verify a word, pick another one. Never invent a word, a meaning or an origin.
5. Write `wotd/latest/index.json` (create the folder if needed) with exactly these keys:
   - `date` (YYYY-MM-DD), `weekday` (full name, e.g. "Thursday")
   - `word` (lowercase, no spaces; hyphen allowed)
   - `pron`: plain ASCII respelling with stress in capitals, like `loo-kyuh-BRAY-shun`
   - `pos`: noun, verb, adjective, adverb ...
   - `definition`: one or two short sentences of plain English
   - `etymology`: one short line such as `From the Latin lucubrare, to work by lamplight.` or ""
   - `image`: the picture id exactly as printed by pick_images.py
   - `connection`: one sentence saying why the picture and the word go together (not shown on
     the device; it keeps the pairing honest and helps the user judge it)
   - `generated_at`: current UTC time, ISO 8601
   Plain ASCII only in every string (no curly quotes, accents or dashes beyond a hyphen). Respect
   the limits in config.json (validate.py checks them).
6. Run `python3 wotd/tools/make_word_image.py wotd/latest/index.json`. It draws the word as a
   large bold JPEG (the device has no big fonts) and records its size in the entry.
7. Publish:
   - `mkdir -p wotd/archive/<date>` and copy `wotd/latest/index.json` and `wotd/latest/word.jpg` there
   - `python3 wotd/tools/make_wotd_index.py` (keeps 30 days, writes archive.json and used_words.txt)
   - `python3 wotd/tools/validate_wotd.py` must print OK. Fix anything it reports.
8. Commit with the message `Word YYYY-MM-DD: <word>` and push to main. Another task also pushes
   to this repo, so run `git pull --rebase origin main` first, and again if the push is
   rejected. Only wotd/ files should be in your commit.
9. If you could not publish (no verifiable word, validation failing), do not push a broken
   entry. Write the reason to `wotd/notes.txt`, commit that file alone, and stop.

## Style

- Difficulty is the point: when two words both fit, take the harder and rarer one, as long as
  it is genuinely in a dictionary and the meaning is clear in one sentence.
- A loose or witty connection beats an obvious one. Examples of good pairings: an eagle owl and
  "lucubration" (work by lamplight, owls and night study); a hot air balloon and "aerostat"; a
  moose and "cervine".
- No commentary in the files. No emojis. No dashes in the prose strings.

## Files

- `wotd/latest/index.json` and `word.jpg`: today's entry (the app reads the archive copy).
- `wotd/archive/<date>/index.json` and `word.jpg`: one folder per day, 30 days kept.
- `wotd/archive.json`: `{"words":[{"date","weekday","word","image"}]}`, newest first.
- `wotd/used_words.txt`: every word ever published, one per line, lowercase.
- `wotd/art/`: the engraving library (`index.json` lists ids, files and subjects). The user adds
  pictures over time. Each is a JPEG that fits 328 x 290 px on a white background.
- `wotd/frames/filigree.jpg`: the lock screen frame the app draws.
