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



def split_statements(sql: str) -> "list[str]":
    """
    Split SQL into statements, for DISPLAY only.

    Execution deliberately sends the whole file in one `cur.execute` so
    the migration is one transaction. This function exists purely so the
    preview above that execution is accurate - and the naive version was
    not.

    WHY THIS IS NOT `sql.split(";")`
    ================================
    005_owner_code.sql contains a COMMENT whose text includes the word
    "countries;". Splitting on every semicolon cut that string literal in
    half and printed two fragments, neither of them valid SQL, under a
    heading claiming five statements where the file has four.

    Nothing broke, because the split output is never executed. But the
    preview is the review step - this script's own docstring says "a
    migration you cannot read before it executes is one you are trusting
    rather than reviewing" - and a preview that misrepresents the
    statements defeats the reason it exists. A dollar-quoted block
    (`DO $$ ... ; ... $$;`) would have been mangled far worse.

    So: track string literals, quoted identifiers, dollar quoting and
    both comment forms, and split only on semicolons outside all of them.
    """
    out, buf = [], []
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]

        if c == "-" and sql.startswith("--", i):                # line comment
            j = sql.find("\n", i)
            i = n if j == -1 else j + 1
            continue

        if c == "/" and sql.startswith("/*", i):                # block comment
            j = sql.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue

        if c == "'":                                            # string literal
            buf.append(c); i += 1
            while i < n:
                buf.append(sql[i])
                if sql[i] == "'":
                    if sql.startswith("''", i):                 # escaped quote
                        buf.append(sql[i + 1]); i += 2; continue
                    i += 1; break
                i += 1
            continue

        if c == '"':                                            # quoted ident
            buf.append(c); i += 1
            while i < n:
                buf.append(sql[i])
                if sql[i] == '"':
                    i += 1; break
                i += 1
            continue

        if c == "$":                                            # dollar quoting
            j = sql.find("$", i + 1)
            if j != -1 and sql[i + 1:j].replace("_", "").isalnum() or (
                    j == i + 1):
                tag = sql[i:j + 1]
                end = sql.find(tag, j + 1)
                if end != -1:
                    buf.append(sql[i:end + len(tag)])
                    i = end + len(tag)
                    continue

        if c == ";":
            stmt = "".join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []
            i += 1
            continue

        buf.append(c)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def _self_test() -> int:
    """`python apply_migration.py --self-test` - no database needed."""
    cases = [
        ("semicolon inside a string literal",
         "COMMENT ON COLUMN t.c IS 'seeded in countries; always';",
         1),
        ("two ordinary statements",
         "ALTER TABLE t ADD COLUMN a TEXT;\nCREATE INDEX i ON t (a);",
         2),
        ("line comment carrying a semicolon",
         "-- note; not a statement\nALTER TABLE t ADD COLUMN a TEXT;",
         1),
        ("block comment carrying a semicolon",
         "/* a; b; c */ ALTER TABLE t ADD COLUMN a TEXT;",
         1),
        ("dollar-quoted body",
         "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$;",
         1),
        ("escaped quote inside a literal",
         "COMMENT ON COLUMN t.c IS 'it''s here; really';",
         1),
        ("trailing statement without a semicolon",
         "ALTER TABLE t ADD COLUMN a TEXT",
         1),
    ]
    failures = 0
    for label, text, expected in cases:
        got = len(split_statements(text))
        ok = got == expected
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}: "
              f"expected {expected}, got {got}")
        if not ok:
            for st in split_statements(text):
                print(f"          {st!r}")
    print()
    if failures:
        print(f"{failures} failure(s).")
        return 1
    print("All cases pass.")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("migration", nargs="?",
                    help="Filename inside schema/, e.g. 002_public_read_grants.sql")
    ap.add_argument("--dry-run", action="store_true",
                    help="Show the statements without running them")
    ap.add_argument("--self-test", action="store_true",
                    help="Check the statement splitter. No database needed.")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.migration:
        ap.error("a migration filename is required (or use --self-test)")
    path = SCHEMA_DIR / args.migration
    if not path.exists():
        available = ", ".join(sorted(p.name for p in SCHEMA_DIR.glob("*.sql")))
        sys.exit(f"No such migration: {path}\nAvailable: {available}")

    sql = path.read_text(encoding="utf-8")

    statements = split_statements(sql)

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
