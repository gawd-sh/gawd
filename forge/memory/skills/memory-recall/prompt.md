# Memory Recall

This skill is deterministic — it does not use an LLM. It fans out to all three memory tiers and returns a ranked, deduplicated, provenance-tagged block.

## What the output means

Each entry in `entries[]` represents one recalled fact with:
- `provenance`: the primary tier it came from (T1 = immediate/live, T2 = focus brief, T3a = long-term archive, T3b = wiki summary)
- `provenance_all`: all tiers that contained this same fact (deduplication collapsed them)
- `text`: the recalled content
- `score`: weighted relevance score (T1 weighted highest for freshness, T3b for density)

## Tier hierarchy

- T1 — Most recent. Live conversation context (lossless-claw messages/summaries).
- T2 — Focus briefs. Active synthesized summaries from recent dreaming cycles.
- T3b — Wiki summaries. Condensed long-term knowledge (densest, preferred under budget pressure).
- T3a — Raw memory-core chunks. Full-text archive (least dense).

## Graceful behavior

If all stores are absent or empty, `entries` is `[]` and `tokens_used` is 0. This is not an error.
