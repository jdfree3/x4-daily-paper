#!/usr/bin/env python3
"""Check the word entry before it is pushed. Exit 1 with messages if anything is wrong.

Usage: python3 wotd/tools/validate_wotd.py
"""
import json, os, re, sys
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
cfg = json.load(open(os.path.join(ROOT, 'config.json')))
L = cfg['limits']
errs = []


def bad(m):
    errs.append(m)


def load(p):
    try:
        return json.load(open(os.path.join(ROOT, p)))
    except Exception as e:
        bad('%s: %s' % (p, e))
        return None


e = load('latest/index.json')
art = load('art/index.json')
arc = load('archive.json')
if e:
    for k in ('date', 'weekday', 'word', 'pron', 'pos', 'definition', 'image', 'connection', 'generated_at'):
        if not isinstance(e.get(k), str) or not e[k].strip():
            bad('latest/index.json: %s missing' % k)
    if not isinstance(e.get('etymology', ''), str):
        bad('etymology must be a string (may be empty)')
    for k, lim in (('word', 'word_chars'), ('pron', 'pron_chars'), ('definition', 'definition_chars'),
                   ('etymology', 'etymology_chars'), ('connection', 'connection_chars')):
        if len(e.get(k, '')) > L[lim]:
            bad('%s is %d chars, limit %d' % (k, len(e[k]), L[lim]))
    for k, v in e.items():
        if isinstance(v, str) and not v.isascii():
            bad('%s has non-ASCII characters (plain ASCII only)' % k)
    if not re.fullmatch(r'[a-z][a-z-]*', e.get('word', '')):
        bad('word must be lowercase letters (hyphen allowed)')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', e.get('date', '')):
        bad('date must be YYYY-MM-DD')
    if art and e.get('image') not in [a['id'] for a in art['images']]:
        bad('image %r is not in art/index.json' % e.get('image'))
    if art and e.get('image') in [a['id'] for a in art['images']]:
        if not os.path.exists(os.path.join(ROOT, 'art', e['image'] + '.jpg')):
            bad('art file missing')
    wi = e.get('word_img') or {}
    p = os.path.join(ROOT, 'latest', wi.get('file', 'word.jpg'))
    if not os.path.exists(p):
        bad('latest/word.jpg missing (run make_word_image.py)')
    else:
        w, h = Image.open(p).size
        if (w, h) != (wi.get('w'), wi.get('h')) or w > 328:
            bad('word.jpg size %dx%d does not match word_img %s' % (w, h, wi))
    d = os.path.join(ROOT, 'archive', e.get('date', 'x'))
    for f in ('index.json', 'word.jpg'):
        if not os.path.exists(os.path.join(d, f)):
            bad('archive/%s/%s missing' % (e.get('date'), f))
    used = open(os.path.join(ROOT, 'used_words.txt')).read().split() if os.path.exists(os.path.join(ROOT, 'used_words.txt')) else []
    if used.count(e.get('word', '')) != 1:
        bad('word must appear exactly once in used_words.txt (run make_wotd_index.py); found %d' % used.count(e.get('word', '')))
if arc:
    w0 = arc['words'][0] if arc.get('words') else None
    if not w0 or (e and w0['date'] != e['date']):
        bad('archive.json newest entry does not match latest')
if errs:
    print('INVALID:')
    for m in errs:
        print(' -', m)
    sys.exit(1)
print('OK:', e['date'], e['word'])
