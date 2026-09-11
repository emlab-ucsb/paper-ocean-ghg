#!/usr/bin/env python3
"""Split a big pile of changes into Overleaf-sized sync batches.

Overleaf pulls the aggregate difference since its last sync, so the unit that
has to stay small is the *sync*, not the commit. The loop this supports is:

    tools/overleaf_sync_batch.py                 # see the plan
    tools/overleaf_sync_batch.py --commit        # commit + push batch 1
    <click Sync in Overleaf, let it finish>
    tools/overleaf_sync_batch.py --commit        # commit + push batch 2
    <sync again>  ... until the plan is empty

Paper-visible files (main.tex, tables/, figures/) are ordered first, so Overleaf
has a correct, compilable manuscript before the bulk data churn goes across.

`git diff --stat` is useless for judging sync size: PNGs and PDFs rewrite
wholesale, so a "3 insertions" commit can carry 20 MB. Everything here is
measured in real blob bytes.
"""
import argparse, os, subprocess, sys

MB = 1024 * 1024
PAPER_PREFIXES = ("figures/", "tables/")
PAPER_FILES = {"main.tex", "point_by_point_response_revision_1.tex",
               "bibliography.bib", "sn-jnl.cls", "sn-nature.bst"}


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True,
                          check=True).stdout


def is_paper(path):
    return path in PAPER_FILES or path.startswith(PAPER_PREFIXES)


def changes_from_worktree():
    out, seen = [], set()
    for line in git("status", "--porcelain=v1", "-uall", "-z").split("\0"):
        if not line.strip():
            continue
        code, path = line[:2], line[3:]
        if not path or path in seen:
            continue
        seen.add(path)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        out.append((code.strip() or "M", path, size))
    return out


def changes_from_range(rng):
    """Rehearsal mode: plan against an existing commit range."""
    base, _, tip = rng.partition("..")
    tip = tip or "HEAD"
    out = []
    for line in git("diff", "--name-status", rng).splitlines():
        parts = line.split("\t")
        code, path = parts[0], parts[-1]
        size = 0
        if code != "D":
            try:
                blob = git("rev-parse", f"{tip}:{path}").strip()
                size = int(git("cat-file", "-s", blob).strip())
            except subprocess.CalledProcessError:
                size = 0
        out.append((code, path, size))
    return out


def plan(changes, max_files, max_bytes):
    tiers = ([c for c in changes if is_paper(c[1])],
             [c for c in changes if not is_paper(c[1])])
    batches = []
    for tier_i, tier in enumerate(tiers):
        cur, cur_bytes = [], 0
        for item in sorted(tier, key=lambda c: c[2]):
            too_big = cur and (len(cur) >= max_files or
                               cur_bytes + item[2] > max_bytes)
            if too_big:
                batches.append((tier_i, cur, cur_bytes))
                cur, cur_bytes = [], 0
            cur.append(item)
            cur_bytes += item[2]
        if cur:
            batches.append((tier_i, cur, cur_bytes))
    return batches


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true",
                    help="commit and push only the FIRST batch, then stop")
    ap.add_argument("--max-files", type=int, default=80)
    ap.add_argument("--max-mb", type=float, default=20.0)
    ap.add_argument("--range", help="rehearse against a commit range, e.g. pre-model-rerun..main")
    ap.add_argument("--message", help="commit message for --commit")
    a = ap.parse_args()

    if a.range and a.commit:
        sys.exit("--range is rehearsal only; it cannot be combined with --commit")

    changes = changes_from_range(a.range) if a.range else changes_from_worktree()
    if not changes:
        print("Nothing to sync - working tree is clean.")
        return

    batches = plan(changes, a.max_files, int(a.max_mb * MB))
    total = sum(b[2] for b in batches)
    label = {0: "paper", 1: "bulk"}

    print(f"{len(changes)} changed files, {total/MB:.1f} MB of new content")
    print(f"-> {len(batches)} sync batches (limits: {a.max_files} files, {a.max_mb:.0f} MB)\n")
    for i, (tier, items, nbytes) in enumerate(batches, 1):
        print(f"Batch {i}/{len(batches)}  [{label[tier]}]  "
              f"{len(items)} files  {nbytes/MB:.1f} MB")
        for code, path, size in items:
            print(f"    {code:<2} {size/MB:8.2f} MB  {path}")
        print()

    if not a.commit:
        print("Dry run. Re-run with --commit to land batch 1, then sync in Overleaf.")
        return

    tier, items, nbytes = batches[0]
    paths = [p for _, p, _ in items]
    msg = a.message or (f"Sync batch 1/{len(batches)} ({label[tier]}): "
                        f"{len(items)} files, {nbytes/MB:.1f} MB")
    subprocess.run(["git", "add", "--", *paths], check=True)
    subprocess.run(["git", "commit", "-m", msg], check=True)
    subprocess.run(["git", "push"], check=True)
    print(f"\nPushed batch 1/{len(batches)}: {len(items)} files, {nbytes/MB:.1f} MB")
    print("NOW: click Sync in Overleaf and let it finish before the next batch.")
    print(f"{len(batches)-1} batches remaining.")


if __name__ == "__main__":
    main()
