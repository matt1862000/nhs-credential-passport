#!/usr/bin/env python3
"""Rebuild training_decision_stats from mandatory_match_decisions."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend import db, decision_engine  # noqa: E402


def main() -> None:
    db.init_db()
    import sqlite3

    with sqlite3.connect(db.DB_PATH) as conn:
        db._ensure_training_decision_stats_table(conn)
        conn.execute("DELETE FROM training_decision_stats")
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT topic_name, credential_id, trust_name, decision, decided_at
            FROM mandatory_match_decisions
            ORDER BY decided_at ASC
            """
        ).fetchall()

    count = 0
    for r in rows:
        topic = (r["topic_name"] or "").strip()
        trust = (r["trust_name"] or "").strip()
        cid = (r["credential_id"] or "").strip()
        dec = (r["decision"] or "").strip().lower()
        if not topic or not trust or dec not in ("accepted", "rejected"):
            continue
        db.training_decision_stats_apply(
            topic_name=topic,
            credential_title=cid,
            trust_name=trust,
            decision=dec,
            decided_at=r["decided_at"] or "",
            previous_decision=None,
        )
        count += 1
    print(f"Backfilled {count} decision rows into training_decision_stats.")


if __name__ == "__main__":
    main()
