"""
Apply a schema migration from schema/ against DATABASE_URL.

    python apply_migration.py 002_public_read_grants.sql
    python apply_migration.py 002_public_read_grants.sql --dry-run

Runs the whole file in one transaction, so a migration either lands
completely or not at all. Prints the statements it is about to run first -
a migration you cannot read before it executes is one you are trusting
rather than reviewing.

DATABASE_URL comes from the ingestion repo's .env, or the environment.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA_DIR = HERE / "schema"


def _load_database_url() -> str:
    url = os.environ.get("DATABASE_URL")
    if url:
        return url

    # The infrastructure repo has no .env of its own; the ingestion repo
    # next door does.
    candidate = HERE.parent / "satellite-platform-ingestion" / ".env"
    if candidate.exists():
        for line in candidate.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")

    sys.exit(
        "DATABASE_URL is not set and no .env was found at "
        f"{candidate}. Set it in the environment and try again."
    )


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("migration", help="Filename inside schema/, e.g. 002_public_read_grants.sql")
    ap.add_argument("--dry-run", action="store_true",
                    help="Show the statements without running them")
    args = ap.parse_args(argv)

    path = SCHEMA_DIR / args.migration
    if not path.exists():
        available = ", ".join(sorted(p.name for p in SCHEMA_DIR.glob("*.sql")))
        sys.exit(f"No such migration: {path}\nAvailable: {available}")

    sql = path.read_text(encoding="utf-8")

    statements = [
        s.strip()
        for s in "\n".join(
            line for line in sql.splitlines() if not line.strip().startswith("--")
        ).split(";")
        if s.strip()
    ]

    print(f"\n{path.name} — {len(statements)} statement(s):\n")
    for s in statements:
        print(f"  {s};")

    if args.dry_run:
        print("\nDry run. Re-run without --dry-run to apply.\n")
        return 0

    import psycopg2

    conn = psycopg2.connect(_load_database_url())
    try:
        with conn:                      # one transaction, all or nothing
            with conn.cursor() as cur:
                cur.execute(sql)
        print(f"\nApplied {path.name}.\n")

        with conn.cursor() as cur:
            cur.execute("""
                SELECT table_name, privilege_type
                  FROM information_schema.role_table_grants
                 WHERE grantee = 'anon' AND table_schema = 'public'
                 ORDER BY table_name, privilege_type
            """)
            rows = cur.fetchall()

        print(f"anon now holds {len(rows)} grant(s) in public:")
        for table, priv in rows:
            print(f"    {priv:<8} {table}")
        print()
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
