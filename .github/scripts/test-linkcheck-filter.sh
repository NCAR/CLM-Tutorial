#!/usr/bin/env bash
# Check that filter-linkcheck-log.sh still picks the problematic URLs and the warnings out of real
# link-checker output. The filter depends on the link checker's output.json and on how Sphinx
# prints warnings, either of which could change with the Sphinx, jupyter-book, or Python version,
# so test-linkcheck-filter.yml runs this when those might have changed.
#
# Needs network access (it checks real URLs), jq, and an environment with requirements.txt
# installed. Can be run from any directory.

set -eu -o pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit template because macOS's `mktemp -d` ignores TMPDIR.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-linkcheck-filter.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
export LOGFILE_BASENAME=build.log

failures=0
fail() {
  echo "::error::$*"
  failures=$((failures + 1))
}

good_url="https://example.com/"
notfound_url="https://example.com/this-page-does-not-exist"
# .invalid is a reserved top-level domain, so this never resolves.
badhost_url="https://nonexistent-host.invalid/"

# Generate the test book here rather than committing it: any Markdown file in the repo gets
# picked up by the real book build, which then fails with "document isn't included in any
# toctree".
book_dir="${work_dir}/book"
mkdir -p "$book_dir"
cat > "${book_dir}/_config.yml" <<'EOF'
title: Link-check filter test
execute:
  execute_notebooks: 'off'
sphinx:
  config:
    linkcheck_timeout: 20
    linkcheck_retries: 1
    # As in the real _config.yml. Makes timeouts report as "timeout" rather than "broken".
    linkcheck_report_timeouts_as_broken: False
EOF
cat > "${book_dir}/_toc.yml" <<'EOF'
format: jb-book
root: index
EOF
cat > "${book_dir}/index.md" <<EOF
# Link-check filter test

- Working: <${good_url}>
- 404: <${notfound_url}>
- Unresolvable host: <${badhost_url}>
- Missing reference (a --nitpick warning): {ref}\`no-such-label\`
EOF
# Not in _toc.yml, so Sphinx warns that it isn't included in any toctree.
cat > "${book_dir}/orphan.md" <<'EOF'
# Orphan page
EOF

echo "=== Running link checker on test book"
full_log="${work_dir}/linkcheck-full.log"
linkcheck_json="${work_dir}/linkcheck-output.json"
if bash "${script_dir}/run-linkcheck.sh" "$book_dir" "$full_log" "$linkcheck_json"; then
  fail "Link checker passed, but the test book has broken links."
fi
if [[ ! -f "$linkcheck_json" ]]; then
  fail "run-linkcheck.sh didn't save the link checker's output.json. Has its location changed?"
# Make sure the working link is in the report, so that the check below that the filter drops it
# means something.
elif ! jq -r --arg url "$good_url" 'select(.uri == $url) | .status' "$linkcheck_json" | grep -qx working; then
  fail "output.json doesn't report ${good_url} as working; can't test that the filter drops it."
fi

echo "=== Filtering link-checker output"
out_dir="${work_dir}/out"
bash "${script_dir}/filter-linkcheck-log.sh" "$full_log" "$linkcheck_json" "$out_dir"
out_log="${out_dir}/${LOGFILE_BASENAME}"
echo "--- Filtered log:"
cat "$out_log"
echo "---"

if [[ ! -f "${out_dir}/log-was-filtered" ]]; then
  fail "Filter found nothing to keep (no log-was-filtered marker)."
fi
# Two non-link warnings, then two broken links. More would mean something is being kept twice
# (e.g., broken links also printed as console warnings) or that the filter is keeping junk.
n_lines=$(wc -l < "$out_log")
if (( n_lines != 4 )); then
  fail "Expected 4 lines in filtered log; got ${n_lines}."
fi
# The non-link warnings fail the job too, so the comment must show them, with paths relative to
# the book directory, and before the links.
for warning in "orphan.md: WARNING: document isn't included in any toctree" "index.md:6: WARNING: undefined label: 'no-such-label'"; do
  if ! head -n 2 "$out_log" | grep -qF "$warning"; then
    fail "First two lines of filtered log don't include the non-link warning: ${warning}"
  fi
done
for link in "index.md:4: broken ${notfound_url} - 404 " "index.md:5: broken ${badhost_url} - "; do
  if ! tail -n 2 "$out_log" | grep -qF "$link"; then
    fail "Last two lines of filtered log don't include a line starting: ${link}"
  fi
done
if grep -qE " ${good_url//./\\.}( |$)" "$out_log"; then
  fail "Filtered log includes the working URL ${good_url}."
fi
if grep -qF -e "$book_dir" -e "$(cd "$book_dir" && pwd -P)" "$out_log"; then
  fail "Filtered log still contains the book directory's absolute path."
fi

echo "=== Filtering output with no output.json and no warnings (should keep the whole log)"
other_log="${work_dir}/other.log"
other_out_dir="${work_dir}/other-out"
printf 'some unrelated failure\nanother line\n' > "$other_log"
bash "${script_dir}/filter-linkcheck-log.sh" "$other_log" "${work_dir}/does-not-exist.json" "$other_out_dir"
if [[ -f "${other_out_dir}/log-was-filtered" ]]; then
  fail "Filter left a log-was-filtered marker when there was nothing to keep."
fi
if ! cmp -s "$other_log" "${other_out_dir}/${LOGFILE_BASENAME}"; then
  fail "Filter didn't keep the whole log when there was nothing to keep."
fi

echo "=== Filtering output with unreadable output.json (should keep the whole log)"
bad_json="${work_dir}/bad.json"
bad_log="${work_dir}/bad.log"
bad_out_dir="${work_dir}/bad-out"
echo '{not json' > "$bad_json"
printf 'index.md:1: WARNING: something\nanother line\n' > "$bad_log"
bash "${script_dir}/filter-linkcheck-log.sh" "$bad_log" "$bad_json" "$bad_out_dir"
if [[ -f "${bad_out_dir}/log-was-filtered" ]]; then
  fail "Filter left a log-was-filtered marker when output.json was unreadable."
fi
if ! cmp -s "$bad_log" "${bad_out_dir}/${LOGFILE_BASENAME}"; then
  fail "Filter didn't keep the whole log when output.json was unreadable."
fi

if (( failures > 0 )); then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
