#!/usr/bin/env bash
# Usage: tools/publish.sh YYYY-MM-DD   (run from repo root after writing editions/latest)
set -euo pipefail
D="$1"
python3 -I tools/make_qr.py
rm -rf "editions/archive/$D"; mkdir -p "editions/archive/$D"
cp -r editions/latest/. "editions/archive/$D/"
python3 -I tools/make_archive_index.py
python3 -I validate.py
python3 -I tools/dedupe_check.py
git checkout -q -B main
git add -A
git commit -qm "Edition $D"
git fetch -q origin && git rebase -q origin/main || { echo "rebase failed"; exit 1; }
git push origin main
