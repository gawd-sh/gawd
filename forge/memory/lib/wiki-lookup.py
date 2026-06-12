#!/usr/bin/env python3
"""wiki-lookup.py — grep wiki topic notes for a query.

Args: WIKI_DIR QUERY [MAX_RESULTS]

Searches *.md files in WIKI_DIR for the query string in:
  - Filename (stem)
  - First 30 lines of each file (title, front-matter, opening paragraph)

Emits a JSON array of:
  {"score": float, "text": str, "provenance": "T3b", "key": str, "path": str}

Score heuristics:
  - 1.0 if query found in filename
  - 0.6 if query found in first 5 lines (title/front-matter)
  - 0.4 if query found in lines 6-30

Degrades gracefully: WIKI_DIR absent / no .md files / any error -> emits [].
"""
import json
import os
import sys


def search_wiki(wiki_dir: str, query: str, max_results: int) -> list:
    if not os.path.isdir(wiki_dir):
        return []

    query_lower = query.lower()
    results = []

    try:
        md_files = [
            f for f in os.listdir(wiki_dir)
            if f.endswith(".md") and os.path.isfile(os.path.join(wiki_dir, f))
        ]
    except OSError:
        return []

    for fname in md_files:
        fpath = os.path.join(wiki_dir, fname)
        stem = os.path.splitext(fname)[0]
        score = 0.0
        snippet = ""

        # Score from filename
        if query_lower in stem.lower():
            score = max(score, 1.0)

        # Score from file content
        try:
            with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
                all_lines = [line.rstrip() for line in fh]

            # Parse front-matter: find opening and closing "---" delimiters.
            # Front-matter is the block between the first "---" on line 0 and
            # the next "---" line.  Everything after the closing delimiter is
            # the body.  Files with no front-matter: treat all lines as body.
            body_start = 0
            if all_lines and all_lines[0] == "---":
                for i in range(1, len(all_lines)):
                    if all_lines[i] == "---":
                        body_start = i + 1
                        break

            body_lines = all_lines[body_start:]
            # First 30 lines of the body for scoring (keeps performance bounded).
            preview_lines = body_lines[:30]
            # First 5 lines of the body for high-score match.
            header = "\n".join(preview_lines[:5])
            if query_lower in header.lower():
                score = max(score, 0.6)

            # Lines 6-30 of the body for lower-score match.
            rest = "\n".join(preview_lines[5:])
            if query_lower in rest.lower():
                score = max(score, 0.4)

            # Also check front-matter text for scoring (filename already scored 1.0).
            fm_text = "\n".join(all_lines[:body_start]).lower()
            if query_lower in fm_text:
                score = max(score, 0.6)

            # Build snippet from first non-empty BODY lines (not front-matter).
            snippet_lines = [l for l in body_lines if l.strip()][:3]
            snippet = " | ".join(snippet_lines)[:512]

        except OSError:
            pass

        if score > 0.0:
            results.append({
                "score": round(score, 4),
                "text": snippet or stem,
                "provenance": "T3b",
                "key": fname,
                "path": fpath,
            })

    results.sort(key=lambda x: x["score"], reverse=True)
    return results[:max_results]


def main():
    if len(sys.argv) < 3:
        print("[]")
        sys.exit(0)

    wiki_dir = sys.argv[1]
    query = sys.argv[2]
    try:
        max_results = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    except (ValueError, IndexError):
        max_results = 5

    try:
        result = search_wiki(wiki_dir, query, max_results)
        print(json.dumps(result))
    except Exception:
        print("[]")
        sys.exit(0)


if __name__ == "__main__":
    main()
