"""Print combined.tex as one flat document, for latexdiff (tools/make_diff.sh).

combined.tex loads main.tex, which loads preamble.tex, the tables under
tables/, and si_content.tex. latexdiff needs that as a single file, and it
must not see the \\combinedbuild switches that choose between the separate and
combined builds: wrapped in latexdiff's markup, a conditional that opens in
one place and closes in another would break the tracked-changes document.
Every \\input in these files sits at the start of its own line, which is the
only form expanded here, so commented-out mentions are left alone.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INPUT = re.compile(r"^\\input\{([^}]*)\}\s*$")


def expand(name):
    path = ROOT / (name if name.endswith(".tex") else name + ".tex")
    lines = []
    for line in path.read_text().splitlines():
        match = INPUT.match(line)
        lines.append(expand(match.group(1)) if match else line)
    return "\n".join(lines)


text = expand("combined.tex")
switches = [
    ("\\def\\combinedbuild{}\n", ""),
    ("\\ifdefined\\combinedbuild\\else\\myexternaldocument{si}\\fi\n", ""),
    ("\\ifdefined\\combinedbuild\n\\newpage\n", "\\newpage\n"),
]
for old, new in switches:
    if text.count(old) != 1:
        sys.exit(f"flatten_combined.py: expected exactly one {old!r}")
    text = text.replace(old, new)
# The \fi closing the SI block is the last one before \end{document}
end = text.rindex("\\end{document}")
fi = text.rindex("\\fi\n", 0, end)
if text[fi + len("\\fi\n"):end].strip():
    sys.exit("flatten_combined.py: text between the SI block's \\fi and \\end{document}")
text = text[:fi] + text[fi + len("\\fi\n"):]
sys.stdout.write(text + "\n")
