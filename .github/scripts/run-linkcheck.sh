#!/usr/bin/env bash
# Run the jupyter-book link checker on a book. Prints the checker's output and saves, for
# filter-linkcheck-log.sh:
#   - A copy of that output made more readable for the PR comment: ANSI color codes (which would
#     render as garbage) are stripped, and file paths are made relative to the book directory.
#   - A copy of the checker's machine-readable report, output.json, if it wrote one.
# Exits with the checker's exit status.
#
# Usage: run-linkcheck.sh BOOK_DIR FULL_LOG LINKCHECK_JSON
#
# Used by gh-page_builder.yml, and by test-linkcheck-filter.sh so that the test exercises the
# exact command CI runs.

set -u -o pipefail
book_dir="$1"
full_log="$2"
linkcheck_json="$3"

# Where Sphinx's linkcheck builder writes its report (one JSON object per checked link) under
# jupyter-book's default output path. Delete any stale copy first so that a run that dies before
# writing one can't pick up an old one.
report="${book_dir}/_build/linkcheck/output.json"
rm -f "$report" "$linkcheck_json"

# The `-W --keep-going --nitpick` in the below command is intended to prevent the tutorial from
# being broken. Do not remove it! If you can't figure out what the problem was, contact Sam Rabin
# (samrabin@ucar.edu) or another software engineer for help.
#
# Intentionally not using --quiet, so that if it takes a long time we can see what the problem is.
status=0
jupyter-book build -W --keep-going --nitpick --builder custom --custom-builder linkcheck "$book_dir" 2>&1 | tee "${full_log}.ansi" || status=$?

# Sphinx prints absolute paths (e.g., "/home/runner/work/CLM-Tutorial/CLM-Tutorial/foo.md:12:
# WARNING: ..."). Strip the book directory's prefix, in both its logical and symlink-resolved
# forms in case they differ. Escape it for use in a sed regex.
escape_for_sed() {
  printf '%s' "$1" | sed -e 's/[][\.|$(){}?+*^]/\\&/g'
}
book_abs="$(cd "$book_dir" && pwd)"
book_abs_resolved="$(cd "$book_dir" && pwd -P)"
strip_logical="s|$(escape_for_sed "$book_abs")/||g"
strip_resolved="s|$(escape_for_sed "$book_abs_resolved")/||g"

# Do this after the fact rather than in a `tee >(sed ...)` process substitution, which this
# script would exit without waiting for.
sed -E -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' -e "$strip_resolved" -e "$strip_logical" "${full_log}.ansi" > "$full_log"
rm "${full_log}.ansi"

if [[ -f "$report" ]]; then
  cp "$report" "$linkcheck_json"
fi

exit "$status"
