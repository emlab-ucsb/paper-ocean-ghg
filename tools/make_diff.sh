#!/usr/bin/env bash
# Builds main_diff.tex: the tracked-changes comparison of the March 2026
# submission against the revised manuscript and Supplementary Information.
# Compile main_diff.tex on Overleaf (Menu > Main document); the response
# letter's line numbers refer to its PDF.
#
# Old side: diff/submitted/main.tex, the combined main + SI file as uploaded
# in March, and the tables it \input'd, taken from git at the submitted commit
# and written to diff/submitted/tables/.
# New side: combined.tex flattened by tools/flatten_combined.py into
# diff/revised_flat.tex, so both sides are one plain document of the same shape.
#
# Tables are treated as pictures (PICTUREENV): a changed table is shown as its
# old version struck out and its new version marked as added, rather than
# marked up cell by cell, which latexdiff cannot do reliably inside tabular.
#
# Usage: tools/make_diff.sh [submitted_commit]   (default 03684ba, 2026-03-16)
set -euo pipefail
cd "$(dirname "$0")/.."

commit="${1:-03684ba}"
old=diff/submitted/main.tex
if [ ! -f "$old" ]; then
  echo "Put the main.tex that was submitted in March at $old" >&2
  exit 1
fi

mkdir -p diff/submitted/tables
grep -o '\\input{tables/[^}]*}' "$old" | sed 's/^\\input{//; s/}$//; s/\.tex$//' | sort -u |
  while read -r table; do
    git show "$commit:$table.tex" > "diff/submitted/$table.tex"
  done

python3 tools/flatten_combined.py > diff/revised_flat.tex

latexdiff --flatten \
  --config="PICTUREENV=(?:picture|DIFnomarkup|tabular|longtable)[\w\d*@]*" \
  "$old" diff/revised_flat.tex > main_diff.tex

echo "Wrote main_diff.tex (old: $old with tables from $commit; new: combined.tex)"
