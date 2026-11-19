#!/usr/bin/env python3
"""Print 6 random candidate pictures for today's word: art that has not been used in the last
history_days. The editor picks the one it can pair with the best hard word.

Usage: python3 wotd/tools/pick_images.py
"""
import json, os, random

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
art = json.load(open(os.path.join(ROOT, 'art', 'index.json')))['images']
cfg = json.load(open(os.path.join(ROOT, 'config.json')))
used = []
p = os.path.join(ROOT, 'archive.json')
if os.path.exists(p):
    used = [w.get('image') for w in json.load(open(p)).get('words', [])][:cfg.get('history_days', 30)]
pool = [a for a in art if a['id'] not in used]
if len(pool) < 6:                     # a small library: allow the oldest used ones back
    pool = art
for a in random.sample(pool, min(6, len(pool))):
    print('%s    (%s)' % (a['id'], a['subject']))
