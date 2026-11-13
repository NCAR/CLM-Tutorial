#!/usr/bin/env bash
# Write the build log file for the PR comment (posted by
# build-jupyter-book-failure-post-comment.yml), keeping only Sphinx's warnings and errors plus
# the problematic URLs.
#
# Usage: LOGFILE_BASENAME=... filter-linkcheck-log.sh FULL_LOG LINKCHECK_JSON OUT_DIR
#   FULL_LOG:       cleaned-up link-checker output, as saved by run-linkcheck.sh
#   LINKCHECK_JSON: the link checker's output.json, as saved by run-linkcheck.sh (may not exist)
#   OUT_DIR:        directory to write ${LOGFILE_BASENAME} (and maybe the log-was-filtered
#                   marker) into
#
# Problematic URLs come from output.json, which has one JSON object per checked link, rather than
# from the console, whose format for link results depends on Sphinx's version and flags. Keep
# status "broken" and "timeout": those are what fail the link check. (Not "redirected", which
# doesn't.) See process_result() in sphinx/builders/linkcheck.py.
#
# Warnings and errors (e.g., a --nitpick missing reference, or a page missing from the toctree)
# fail the job too, but output.json doesn't have them, so take those from the console; otherwise
# fixing the links would leave the job failing with no explanation. These print as
# "path:line: WARNING: ..." but can start mid-line (e.g., "checking consistency... path: WARNING:
# ..."), so the pattern isn't anchored. Only the first line of a multi-line message is kept. If
# Sphinx ever prints broken links as warnings too (it does without --keep-going, or with --quiet,
# or in Sphinx 8), they'll appear twice in the comment.
#
# Warnings come first, then links. That matches the order the console prints them in.
#
# If neither source has anything, the job failed for some other reason (e.g., a crash), so keep
# the whole log. Same if output.json can't be read.
#
# test-linkcheck-filter.sh checks this against real link-checker output.

set -eu
full_log="$1"
linkcheck_json="$2"
out_dir="$3"

mkdir -p "$out_dir"
out_log="${out_dir}/${LOGFILE_BASENAME}"

keep_whole_log() {
  cp "$full_log" "$out_log"
  exit 0
}

links=""
if [[ -f "$linkcheck_json" ]]; then
  # E.g., "index.md:12: broken https://... - 404 Client Error: ..."
  jq_filter='select(.status == "broken" or .status == "timeout")
    | "\(.filename)\(if .lineno then ":\(.lineno)" else "" end): \(.status) \(.uri)\(if (.info // "") != "" then " - \(.info)" else "" end)"'
  if ! links="$(jq -r "$jq_filter" "$linkcheck_json")"; then
    echo "::warning::Couldn't read ${linkcheck_json}; keeping the whole log."
    keep_whole_log
  fi
fi

warnings="$(grep -E '(WARNING|ERROR|CRITICAL): ' "$full_log" || true)"

if [[ -z "$warnings" && -z "$links" ]]; then
  keep_whole_log
fi

: > "$out_log"
if [[ -n "$warnings" ]]; then
  printf '%s\n' "$warnings" >> "$out_log"
fi
if [[ -n "$links" ]]; then
  printf '%s\n' "$links" >> "$out_log"
fi
# Marker telling build-jupyter-book-failure-post-comment.yml to say the log was filtered. The
# filename must match the one checked there.
touch "${out_dir}/log-was-filtered"
