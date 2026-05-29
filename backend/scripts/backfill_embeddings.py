#!/usr/bin/env python3
"""Warm topic and credential embedding caches in SQLite (optional one-off)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend import db, mandatory_matching as mm  # noqa: E402


def _distinct_trusts() -> list[str]:
    import sqlite3

    with sqlite3.connect(db.DB_PATH) as conn:
        rows = conn.execute(
            """
            SELECT DISTINCT TRIM(trust_name) AS t
            FROM trust_mandatory_topics
            WHERE TRIM(COALESCE(trust_name, '')) != ''
            UNION
            SELECT DISTINCT TRIM(current_trust) AS t
            FROM users
            WHERE premium = 0 AND TRIM(COALESCE(current_trust, '')) != ''
            """
        ).fetchall()
    return sorted({str(r[0]).strip() for r in rows if r and r[0]})


def _distinct_module_names() -> list[str]:
    import sqlite3

    names: set[str] = set()
    with sqlite3.connect(db.DB_PATH) as conn:
        rows = conn.execute("SELECT wallet_json FROM user_wallets").fetchall()
    for (raw,) in rows:
        try:
            wallet = json.loads(raw or "[]")
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(wallet, list):
            continue
        for c in wallet:
            if not isinstance(c, dict) or c.get("revoked"):
                continue
            pl = c.get("payload") if isinstance(c.get("payload"), dict) else c
            if not isinstance(pl, dict):
                pl = c
            name = (pl.get("module_name") or c.get("module_name") or "").strip()
            if name:
                names.add(name)
    return sorted(names)


def main() -> None:
    db.init_db()
    trusts = _distinct_trusts()
    topic_count = 0
    for trust in trusts:
        topics = db.mandatory_topics_list(trust, seed_defaults=False)
        if not topics:
            topics = db.mandatory_topics_list(trust, seed_defaults=True)
        before = len(mm._semantic_pack_cache.get(trust, {}).get("topics") or {})
        mm.prepare_semantic_match_cache(trust, topics)
        after = len(mm._semantic_pack_cache.get(trust, {}).get("topics") or {})
        topic_count += max(after, before, len(topics))
        print(f"  trust {trust!r}: {len(topics)} topics")

    cred_count = 0
    modules = _distinct_module_names()
    for name in modules:
        vec = mm._embed_text_cached(name, kind="credential")
        if vec:
            cred_count += 1
    print(f"Done: warmed packs for {len(trusts)} trust(s), {cred_count}/{len(modules)} credential module name(s).")


if __name__ == "__main__":
    main()
