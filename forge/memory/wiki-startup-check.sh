#!/usr/bin/env bash
# wiki-startup-check.sh — refuse to run the wiki bridge if its output path is
# inside the ingest scope (recursion guard #1, spec §4.3). Fail LOUD, not
# silently recurse. Exit 0 = disjoint/safe; exit 3 = output ⊆ ingest (refuse).
#
# Required env:
#   GAWD_INGEST_SCOPE  — the directory tree the wiki bridge reads from
#   GAWD_WIKI_OUT      — the directory the wiki bridge writes summaries into
#
# The guard: if GAWD_WIKI_OUT starts with GAWD_INGEST_SCOPE/ (or equals it),
# the output would be re-ingested on the next run — the 79K-iteration recursion.
set -euo pipefail
INGEST="${GAWD_INGEST_SCOPE:?GAWD_INGEST_SCOPE required}"
OUT="${GAWD_WIKI_OUT:?GAWD_WIKI_OUT required}"
# Normalize (strip trailing slash).
INGEST="${INGEST%/}"; OUT="${OUT%/}"
case "$OUT/" in
  "$INGEST"/*)
    echo "FATAL: wiki output ($OUT) is INSIDE ingest scope ($INGEST). Refusing to" >&2
    echo "       start the bridge — this re-arms the 79K-iteration recursion." >&2
    exit 3 ;;
esac
echo "OK: wiki output ($OUT) is disjoint from ingest scope ($INGEST)."
exit 0
