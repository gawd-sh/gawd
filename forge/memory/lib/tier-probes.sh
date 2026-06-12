#!/usr/bin/env bash
# tier-probes.sh — per-tier memory read probe library
#
# Four functions: probe_t1, probe_t2, probe_t3a, probe_t3b
# Each takes a single query argument.
# Each emits a JSON array of {"score":float,"text":str,"provenance":"T1|T2|T3a|T3b","key":str}
# Each ALWAYS exits 0. On any error / empty / absent store -> emits [] and returns 0.
#
# Env overrides (for testing with alternate stores):
#   GAWD_LCM_DB       - default: /home/gawd/.openclaw/lcm.db
#   GAWD_MEM_DB       - default: /home/gawd/.openclaw/memory/main.sqlite
#   GAWD_WIKI_DIR     - default: /home/gawd/.openclaw/workspace/wiki
#   GAWD_NORMALIZE_T3A - default: $(dirname $BASH_SOURCE)/normalize-t3a.py
#   GAWD_WIKI_LOOKUP  - default: $(dirname $BASH_SOURCE)/wiki-lookup.py
#   GAWD_MAX_RESULTS  - max rows per probe (default: 5)

_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LCM_DB="${GAWD_LCM_DB:-/home/gawd/.openclaw/lcm.db}"
MEM_DB="${GAWD_MEM_DB:-/home/gawd/.openclaw/memory/main.sqlite}"
WIKI_DIR="${GAWD_WIKI_DIR:-/home/gawd/.openclaw/workspace/wiki}"
NORMALIZE_T3A="${GAWD_NORMALIZE_T3A:-${_PROBE_DIR}/normalize-t3a.py}"
WIKI_LOOKUP="${GAWD_WIKI_LOOKUP:-${_PROBE_DIR}/wiki-lookup.py}"
MAX_RESULTS="${GAWD_MAX_RESULTS:-5}"

# ---------------------------------------------------------------------------
# probe_t1 — immediate context from lcm.db
#   Queries messages_fts (FTS5) and summaries_fts (FTS5) for recent content.
#   Table: messages_fts(content) — porter unicode61 tokenizer
#   Table: summaries_fts(summary_id UNINDEXED, content) — same tokenizer
#   Score: fts5 bm25 rank (negated so higher = better; normalized to 0..1 range).
#   Degrades gracefully: returns [] if db absent, query fails, or no results.
# ---------------------------------------------------------------------------
probe_t1() {
  local query="${1:-}"
  local result

  if [ -z "$query" ] || [ ! -f "$LCM_DB" ]; then
    echo "[]"
    return 0
  fi

  result="$(python3 - "$LCM_DB" "$query" "$MAX_RESULTS" <<'PYEOF'
import sys, sqlite3, json, math

db_path, query, max_results = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    rows = []

    # Sanitize query for FTS5: escape double quotes, wrap in quotes
    safe_q = query.replace('"', '""')
    fts_query = f'"{safe_q}"'

    # Query messages_fts
    try:
        cur = conn.execute(
            "SELECT content, bm25(messages_fts) AS rank FROM messages_fts "
            "WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?",
            (fts_query, max_results)
        )
        for r in cur.fetchall():
            # bm25 returns negative values; lower (more negative) = better match
            raw_rank = r["rank"] if r["rank"] is not None else -1.0
            score = max(0.0, min(1.0, 1.0 / (1.0 + abs(raw_rank))))
            rows.append({
                "score": round(score, 4),
                "text": (r["content"] or "")[:512],
                "provenance": "T1",
                "key": f"msg:{hash(r['content']) & 0xFFFFFF}"
            })
    except Exception:
        pass

    # Query summaries_fts
    try:
        cur = conn.execute(
            "SELECT summary_id, content, bm25(summaries_fts) AS rank FROM summaries_fts "
            "WHERE summaries_fts MATCH ? ORDER BY rank LIMIT ?",
            (fts_query, max_results)
        )
        for r in cur.fetchall():
            raw_rank = r["rank"] if r["rank"] is not None else -1.0
            score = max(0.0, min(1.0, 1.0 / (1.0 + abs(raw_rank))))
            rows.append({
                "score": round(score, 4),
                "text": (r["content"] or "")[:512],
                "provenance": "T1",
                "key": f"sum:{r['summary_id'] or 'unknown'}"
            })
    except Exception:
        pass

    conn.close()
    # Sort by score desc, cap total
    rows.sort(key=lambda x: x["score"], reverse=True)
    print(json.dumps(rows[:max_results]))

except Exception:
    print("[]")
PYEOF
)" 2>/dev/null || result="[]"

  # Validate output is a JSON array; fall back to [] on parse error
  echo "$result" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert isinstance(a,list); print(json.dumps(a))' 2>/dev/null || echo "[]"
  return 0
}

# ---------------------------------------------------------------------------
# probe_t2 — focus briefs from lcm.db (T2 store)
#   Queries focus_briefs WHERE status='active', content LIKE %query%.
#   No topic column — matches on content and prompt text.
#   Key: brief_id. Provenance: T2.
#   Score: 0.7 fixed (active briefs are always high-relevance context).
#   Degrades gracefully: returns [] if db absent, query fails, or no results.
# ---------------------------------------------------------------------------
probe_t2() {
  local query="${1:-}"
  local result

  if [ -z "$query" ] || [ ! -f "$LCM_DB" ]; then
    echo "[]"
    return 0
  fi

  result="$(python3 - "$LCM_DB" "$query" "$MAX_RESULTS" <<'PYEOF'
import sys, sqlite3, json

db_path, query, max_results = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    like_pat = f"%{query}%"
    cur = conn.execute(
        """SELECT brief_id, session_key, prompt, content, covered_latest_at,
                  created_at, updated_at
           FROM focus_briefs
           WHERE status = 'active'
             AND (content LIKE ? OR prompt LIKE ?)
           ORDER BY created_at DESC
           LIMIT ?""",
        (like_pat, like_pat, max_results)
    )
    rows = []
    for r in cur.fetchall():
        rows.append({
            "score": 0.7,
            "text": (r["content"] or "")[:512],
            "provenance": "T2",
            "key": r["brief_id"] or "unknown",
            "session_key": r["session_key"] or "",
            "prompt": r["prompt"] or "",
            "covered_latest_at": r["covered_latest_at"] or ""
        })
    conn.close()
    print(json.dumps(rows))

except Exception:
    print("[]")
PYEOF
)" 2>/dev/null || result="[]"

  echo "$result" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert isinstance(a,list); print(json.dumps(a))' 2>/dev/null || echo "[]"
  return 0
}

# ---------------------------------------------------------------------------
# probe_t3a — long-term memory from memory/main.sqlite (chunks_fts)
#   memory-core CLI requires an OpenAI embedding provider — not available in
#   this container. Falls back to direct FTS5 query on chunks_fts table.
#   Table: chunks_fts(text, id UNINDEXED, path UNINDEXED, source UNINDEXED, ...)
#   Key: chunk id. Provenance: T3a.
#   Degrades gracefully: returns [] if main.sqlite absent, query fails, or empty.
# ---------------------------------------------------------------------------
probe_t3a() {
  local query="${1:-}"
  local result

  if [ -z "$query" ] || [ ! -f "$MEM_DB" ]; then
    echo "[]"
    return 0
  fi

  result="$(python3 - "$MEM_DB" "$query" "$MAX_RESULTS" <<'PYEOF'
import sys, sqlite3, json

db_path, query, max_results = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    safe_q = query.replace('"', '""')
    fts_query = f'"{safe_q}"'

    try:
        cur = conn.execute(
            "SELECT text, id, path, source, bm25(chunks_fts) AS rank "
            "FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?",
            (fts_query, max_results)
        )
        rows = []
        for r in cur.fetchall():
            raw_rank = r["rank"] if r["rank"] is not None else -1.0
            score = max(0.0, min(1.0, 1.0 / (1.0 + abs(raw_rank))))
            rows.append({
                "score": round(score, 4),
                "text": (r["text"] or "")[:512],
                "provenance": "T3a",
                "key": r["id"] or r["path"] or "unknown",
                "path": r["path"] or "",
                "source": r["source"] or "memory"
            })
        conn.close()
        rows.sort(key=lambda x: x["score"], reverse=True)
        print(json.dumps(rows))
    except Exception:
        conn.close()
        print("[]")

except Exception:
    print("[]")
PYEOF
)" 2>/dev/null || result="[]"

  echo "$result" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert isinstance(a,list); print(json.dumps(a))' 2>/dev/null || echo "[]"
  return 0
}

# ---------------------------------------------------------------------------
# probe_t3b — wiki topic notes (WIKI_DIR/*.md front-matter + title grep)
#   Searches for query in wiki note titles and first N lines.
#   WIKI_DIR may not exist — degrades gracefully to [].
#   Key: filename. Provenance: T3b.
# ---------------------------------------------------------------------------
probe_t3b() {
  local query="${1:-}"
  local result

  if [ -z "$query" ] || [ ! -d "$WIKI_DIR" ]; then
    echo "[]"
    return 0
  fi

  result="$(python3 "$WIKI_LOOKUP" "$WIKI_DIR" "$query" "$MAX_RESULTS" 2>/dev/null)" || result="[]"

  echo "$result" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert isinstance(a,list); print(json.dumps(a))' 2>/dev/null || echo "[]"
  return 0
}
