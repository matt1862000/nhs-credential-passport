"""CLI for scheduled HR email digests: python -m backend.hr_email_cli"""
import sys

from . import db
from .hr_email import send_daily_digests


def main() -> int:
    db.init_db()
    if len(sys.argv) < 2 or sys.argv[1] not in ("daily", "digest"):
        print("Usage: python -m backend.hr_email_cli daily", file=sys.stderr)
        return 1
    sent = send_daily_digests()
    print(f"HR daily digests sent: {sent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
