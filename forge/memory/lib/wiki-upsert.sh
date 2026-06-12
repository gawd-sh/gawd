#!/usr/bin/env bash
# wiki-upsert.sh — recursion guard #3 (spec §4.3, Task 3.2).
#
# PURPOSE: Hash-upsert idempotency for wiki topic notes.
#
# SINGLE RESPONSIBILITY: hash I/O + dedup check only. This guard does NOT
# implement wiki synthesis (that is Task 3.3). It receives an already-computed
# body and either writes it (new/changed) or skips it (identical hash).
#
# HOW IT WORKS:
#   1. For a given (topic_key, body), build the on-disk representation with
#      generation:1 front-matter (guard #2 composes here: notes written here
#      are structurally blocked from re-ingestion by wiki-gen-guard.sh).
#   2. Hash the candidate note (sha1sum over the rendered content).
#   3. If the file already exists AND its hash matches the candidate: NO write.
#      → No mtime change → no fs event → no wiki bridge re-trigger.
#   4. If the file is new OR its hash differs: overwrite-in-place via atomic
#      temp+mv so a crash leaves either the old version or the new version,
#      never a partial write.
#   5. Always ONE file per topic key (no duplicates, never appended to).
#
# RECURSION-PREVENTION PROPERTY:
#   Guard #1 (disjoint paths, wiki-startup-check.sh): notes written here live
#   under GAWD_WIKI_OUT, which is disjoint from GAWD_INGEST_SCOPE. The wiki
#   bridge therefore cannot see them during its ingest scan.
#   Guard #2 (generation tag, wiki-gen-guard.sh): notes carry generation:1, so
#   gen_should_ingest() returns 1 (skip) for them even if the paths somehow
#   overlapped.
#   Guard #3 (this file): identical content on re-run = no write = no fs event
#   = no ingest notification = no synthesis loop.
#   All three compose here: the note is in the right place (guard #1), tagged
#   to be skipped at admission (guard #2), and skips writing when unchanged
#   (guard #3).
#
# ENVIRONMENT:
#   GAWD_WIKI_OUT — absolute path to the wiki output directory. MUST be
#                   disjoint from GAWD_INGEST_SCOPE (enforced by guard #1 at
#                   startup; not re-checked here for performance). Defaults to
#                   /home/gawd/.openclaw/workspace/wiki.
#
# USAGE:
#   source wiki-upsert.sh
#   wiki_upsert "topic-key" "body text for the topic note"
#
# NOTE: Requires sha1sum (coreutils). The temp file is created in the same
#       directory as the target so the atomic mv is always on the same
#       filesystem (no cross-device rename risk).

GAWD_WIKI_OUT="${GAWD_WIKI_OUT:-/home/gawd/.openclaw/workspace/wiki}"

# wiki_upsert <topic_key> <body>
#
# Upserts a topic note to GAWD_WIKI_OUT/<topic_key>.md with hash-idempotency.
# If the rendered note (including generation:1 front-matter) is byte-for-byte
# identical to the file on disk, NO write is performed — mtime is preserved.
# Returns 0 always (errors are non-fatal; a failed upsert is not a crash).
wiki_upsert() {
    local key="$1" body="$2"
    local dir="${GAWD_WIKI_OUT}"
    local f="${dir}/${key}.md"
    local tmp newhash oldhash

    # Ensure the output directory exists.
    mkdir -p "$dir" || { return 0; }

    # Build a temp file with the full note content including generation:1
    # front-matter. Use the same directory so mv is always same-filesystem.
    tmp="$(mktemp "${dir}/.wiki-upsert-XXXXXX.tmp")" || { return 0; }

    # Write the note. generation:1 is the guard #2 tag that prevents re-ingest.
    # topic field in front-matter is informational.
    printf -- '---\ngeneration: 1\ntopic: %s\n---\n%s\n' "$key" "$body" > "$tmp"

    # Hash the candidate.
    newhash="$(sha1sum "$tmp" 2>/dev/null | awk '{print $1}')"

    # If the file already exists, compare hashes.
    if [ -f "$f" ]; then
        oldhash="$(sha1sum "$f" 2>/dev/null | awk '{print $1}')"
        if [ -n "$newhash" ] && [ "$newhash" = "$oldhash" ]; then
            # Identical content — discard temp, leave file untouched.
            rm -f "$tmp"
            return 0
        fi
    fi

    # New file or changed content: atomic overwrite-in-place.
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 0; }

    return 0
}
