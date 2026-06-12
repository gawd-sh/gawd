#!/usr/bin/env python3
"""normalize-t3a.py — normalize memory-core search JSON to tier-probe shape.

Reads `openclaw memory search --json` output from stdin:
  {"results": [...]}

Each result from memory-core search (when the embedding provider IS available)
has these keys (observed from source + empty-index run):
  - text or chunk (the memory text)
  - score (float, 0..1 similarity)
  - path or source (file path the chunk came from)
  - id (optional chunk id)

Emits a JSON array of:
  {"score": float, "text": str, "provenance": "T3a", "key": str, "path": str}

Degrades gracefully: on any parse error or missing keys -> emits [].

Usage:
  node openclaw memory search --json --query "..." | python3 normalize-t3a.py
"""
import json
import sys


def normalize(raw: dict) -> list:
    results = raw.get("results", [])
    if not isinstance(results, list):
        return []

    out = []
    for r in results:
        if not isinstance(r, dict):
            continue

        # text field: try 'text', then 'chunk', then 'content'
        text = r.get("text") or r.get("chunk") or r.get("content") or ""
        text = str(text)[:512]

        # score: float 0..1; fall back to 0.5 if absent/non-numeric
        try:
            score = float(r.get("score", 0.5))
            score = max(0.0, min(1.0, score))
        except (TypeError, ValueError):
            score = 0.5

        # key: prefer chunk id, then path
        key = str(r.get("id") or r.get("path") or "unknown")

        # path
        path = str(r.get("path") or r.get("source") or "")

        out.append({
            "score": round(score, 4),
            "text": text,
            "provenance": "T3a",
            "key": key,
            "path": path,
        })

    out.sort(key=lambda x: x["score"], reverse=True)
    return out


def main():
    try:
        raw = json.load(sys.stdin)
        result = normalize(raw)
        print(json.dumps(result))
    except Exception:
        print("[]")
        sys.exit(0)


if __name__ == "__main__":
    main()
