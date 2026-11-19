#!/usr/bin/env python3
"""Keep the newest 30 archive days, write wotd/archive.json, and record the word in used_words.txt.

Usage: python3 wotd/tools/make_wotd_index.py
"""
import json, os, shutil

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
KEEP = json.load(open(os.path.join(ROOT, 'config.json'))).get('history_days', 30)
arch = os.path.join(ROOT, 'archive')
days = sorted([d for d in os.listdir(arch) if os.path.exists(os.path.join(arch, d, 'index.json'))], reverse=True)
for old in days[KEEP:]:
    shutil.rmtree(os.path.join(arch, old))
words = []
used_path = os.path.join(ROOT, 'used_words.txt')
used = set(open(used_path).read().split()) if os.path.exists(used_path) else set()
for d in days[:KEEP]:
    e = json.load(open(os.path.join(arch, d, 'index.json')))
    words.append({'date': e['date'], 'weekday': e.get('weekday', ''), 'word': e['word'], 'image': e['image']})
    used.add(e['word'].lower())
json.dump({'words': words}, open(os.path.join(ROOT, 'archive.json'), 'w'), indent=1)
open(used_path, 'w').write('\n'.join(sorted(used)) + '\n')
print('archive.json: %d words; used_words.txt: %d' % (len(words), len(used)))
