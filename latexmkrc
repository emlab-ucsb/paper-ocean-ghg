# main.tex and si.tex cross-reference each other through the xr package, which
# reads the other document's .aux file. This rule lets latexmk (which Overleaf
# uses) compile the other document whenever that .aux is missing or out of date.
add_cus_dep('tex', 'aux', 0, 'makeexternaldocument');
sub makeexternaldocument {
    # Skip the document latexmk is already building, or it would recurse forever
    if (!($root_filename eq $_[0])) {
        system("latexmk -cd -pdf \"$_[0]\"");
    }
}
