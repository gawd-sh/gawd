#!/usr/bin/env bash
# wiki-gen-guard.sh — recursion guard #2 (spec §4.3, task 3.1).
#
# PURPOSE: Prevent memory-wiki from re-ingesting its own summaries.
#
# HOW IT WORKS:
#   Source artifacts (day-notes written by safe-dream.sh T3 path) carry
#   front-matter "generation: 0". Wiki summaries written by wiki-upsert.sh
#   carry "generation: 1". This guard reads the generation tag from a file's
#   YAML front-matter and returns 0 (admit) for gen<1 (source) or 1 (skip)
#   for gen>=1 (summary). Files with no front-matter or no generation key
#   are treated as generation:0 (source) and admitted.
#
# RECURSION-PREVENTION PROPERTY:
#   A gen:1 summary CANNOT pass gen_should_ingest, so it can never be fed
#   back into the wiki synthesis step to produce a gen:2 summary-of-summary.
#   The 79K-iteration recursion required re-ingesting wiki output; this guard
#   structurally closes that path at the admission point, independent of the
#   other two guards (disjoint paths = guard #1; hash-upsert = guard #3).
#
# USAGE:
#   source wiki-gen-guard.sh
#   gen_should_ingest "/path/to/file.md"
#   # Returns: 0 = admit (gen<1 or untagged); 1 = skip (gen>=1)
#
# NOTE: This file is sourced by the wiki synthesis step inside safe-dream.sh
#       (the T3 summaries section) and directly by test-wiki-gen-guard.sh and
#       test-safe-dream.sh. safe-dream.sh itself sources it via the T3 wiki block
#       (not Task 2.3 — Task 2.3 sources dream-cursor.sh and dream-pace.sh).
#       This file is intentionally free of side-effects on source — only defines
#       the function. No subshells, no writes, no network calls.

# gen_should_ingest <path>
# Returns 0 (true, ingest is allowed) if the file's generation < 1.
# Returns 1 (false, skip) if generation >= 1.
# Files that do not exist return 1 (skip — cannot ingest a missing file).
# Files with no YAML front-matter or no generation key: treated as generation:0 (admit).
gen_should_ingest() {
    local f="$1"

    # Missing file: skip.
    [ -f "$f" ] || return 1

    # Extract the generation value from YAML front-matter.
    # YAML front-matter is bounded by "---" on its own line at the start and end.
    # We parse with awk: enter front-matter on the first "---" at line 1, exit on
    # the second "---", extract the value of "generation:" if present.
    # If no front-matter or no generation key: gen defaults to empty -> 0.
    local gen
    gen="$(awk '
        NR == 1 && $0 ~ /^---\r?$/ { in_fm = 1; next }
        in_fm && $0 ~ /^---\r?$/   { exit }
        in_fm && /^generation:/ {
            # grab everything after the colon, strip leading whitespace
            sub(/^generation:[ \t]*/, "")
            print $0
            exit
        }
    ' "$f" 2>/dev/null)"

    # Default to 0 if not found or empty.
    gen="${gen:-0}"

    # Strip any trailing whitespace or carriage returns (CRLF safety).
    gen="$(printf '%s' "$gen" | tr -d '[:space:]')"

    # Validate: must be a non-negative integer. If not parseable, treat as 0.
    if ! printf '%s' "$gen" | grep -qE '^[0-9]+$'; then
        gen=0
    fi

    # Admit (return 0) if generation < 1; skip (return 1) if generation >= 1.
    if [ "$gen" -ge 1 ] 2>/dev/null; then
        return 1  # skip: this is a summary (gen1+)
    fi

    return 0  # admit: this is a source artifact (gen0)
}
