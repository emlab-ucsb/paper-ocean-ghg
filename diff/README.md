# Tracked-changes comparison

`tools/make_diff.sh` writes `main_diff.tex` (repo root), the tracked-changes
version of the revised manuscript and Supplementary Information against the
combined main + SI document as originally submitted. Compile it on Overleaf
(Menu > Main document > `main_diff.tex`); the response letter's line numbers
refer to its PDF.

1. Put the `main.tex` that was originally submitted at `diff/submitted/main.tex`.
   It is there now: the copy the authors confirmed on 2026-09-29, identical to
   `main.tex` at tag `v1-submitted` (commit f499db7, 2026-07-09).
2. Run `tools/make_diff.sh [commit]`, where `commit` is the git commit whose
   `tables/` the submitted file used (default `v1-submitted`). The script
   copies those tables into `diff/submitted/tables/`, flattens `combined.tex`
   into `diff/revised_flat.tex`, and runs latexdiff.
3. Commit `diff/submitted/` and `main_diff.tex`, push, and compile on Overleaf.

Regenerate after any later text change, since every line number moves with it.
