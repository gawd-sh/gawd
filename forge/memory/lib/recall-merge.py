#!/usr/bin/env python3
"""recall-merge.py — merge per-tier probe results into ONE ranked, deduped,
budget-fit, provenance-tagged context block. Stdin: JSON {tier: [entries]}.
Implements spec §3.2: tier-weighted ranking, provenance dedup, summary-first
budget fit, graceful subset. Never raises on a missing/empty tier."""
import sys, json, argparse, hashlib

# Tier immediacy/density weights (spec §3.2 rule 1): T1 freshest, T3b densest.
TIER_W = {"T1": 1.30, "T2": 1.15, "T3b": 1.10, "T3a": 1.00}
# Densest-first preference order for budget fit (rule 3).
DENSITY_ORDER = {"T3b": 0, "T2": 1, "T3a": 2, "T1": 3}

def norm_key(e):
    # Dedup key = normalized text content hash prefix (rule 2). 'key' may differ
    # across tiers for the same fact, so dedup on content, not the source key.
    h = hashlib.sha1(" ".join(e.get("text","").lower().split()).encode()).hexdigest()
    return h[:12]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, default=2000)  # token budget (approx chars/4)
    args = ap.parse_args()
    try:
        tiers = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"entries": [], "note": "empty-input"})); return
    flat = []
    for tier, entries in (tiers or {}).items():
        for e in (entries or []):
            e = dict(e); e.setdefault("provenance", tier)
            e["_w"] = float(e.get("score", 0.0)) * TIER_W.get(e["provenance"], 1.0)
            flat.append(e)
    # Dedup by content; merge provenance; keep highest weighted score.
    merged = {}
    for e in flat:
        k = norm_key(e)
        if k not in merged:
            e["provenance_all"] = [e["provenance"]]
            merged[k] = e
        else:
            m = merged[k]
            if e["provenance"] not in m["provenance_all"]:
                m["provenance_all"].append(e["provenance"])
            if e["_w"] > m["_w"]:
                # prefer the denser representation's text/provenance
                if DENSITY_ORDER.get(e["provenance"],9) < DENSITY_ORDER.get(m["provenance"],9):
                    m["text"], m["provenance"] = e["text"], e["provenance"]
                m["_w"] = e["_w"]
    ranked = sorted(merged.values(), key=lambda x: x["_w"], reverse=True)
    # Budget fit, densest-first within ranked order.
    out, used = [], 0
    for e in sorted(ranked, key=lambda x: (DENSITY_ORDER.get(x["provenance"],9), -x["_w"])):
        cost = max(1, len(e.get("text","")) // 4)
        if used + cost > args.budget and out:
            continue
        used += cost
        out.append({"provenance": e["provenance"], "provenance_all": e["provenance_all"],
                    "text": e["text"], "score": round(e["_w"], 4)})
    out.sort(key=lambda x: x["score"], reverse=True)
    print(json.dumps({"entries": out, "tokens_used": used}))

if __name__ == "__main__":
    main()
