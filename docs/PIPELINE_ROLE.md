# The pipeline role — rotation and cutover (AD-065)

`019_pipeline_role.sql` creates a least-privilege role for the scheduled
workflows. **Applying it changes nothing about how anything connects.**
It is safe to apply and walk away; the cutover below is a separate,
deliberate step.

## Why

Every scheduled workflow connects as `postgres.<project>`. That role can
DROP the catalogue, read every row regardless of RLS, TRUNCATE tables,
and create superusers. Five workflows hold that credential in their
environment, on a schedule, unattended — to INSERT and UPDATE a handful
of tables.

It has been the largest remaining exposure since AD-064 closed on
2026-09-14. Locking the dependencies narrowed *what can run* with that
credential; it did nothing about *what the credential can do*.

## What the role can and cannot do

Verified against PostgreSQL 16 — 18 assertions, by becoming the role
rather than by reading the grant table (AD-071).

| | |
|---|---|
| SELECT, INSERT, UPDATE | the 15 tables the pipelines write |
| SELECT only | `countries`, `domains`, `technologies`, `technology_categories` |
| **DELETE** | **no** |
| **TRUNCATE** | **no** |
| DDL (CREATE / DROP / ALTER) | no |
| CREATE ROLE, superuser, BYPASSRLS | no |

`login=false super=false createrole=false bypassrls=false inherit=false`
until you set a password.

**The prune scripts keep the operator credential.**
`truncate_archived.py` and `cleanup_tle_history.py` delete rows, and that
stays a decision a person makes. The 2026-09-10 archive work exists
because losing rows is the failure this project can least afford; a
scheduled job that can delete is one bad watermark away from doing it.

## Rotation — you run this, not Claude

**Claude must not see this password.** Do not paste it into a chat, a
commit, or a migration. Generate it in your password manager, or:

```powershell
# 32 random bytes, base64 — never echoed anywhere but your clipboard
[Convert]::ToBase64String((1..24 | % {Get-Random -Max 256})) | Set-Clipboard
```

Then, in the Supabase SQL editor (not a file in this repo):

```sql
ALTER ROLE pipeline LOGIN PASSWORD '<paste>';
```

That statement is the only place the password appears, and the SQL
editor does not persist it into the repository.

## Cutover

Do these in order. Each is reversible on its own.

1. **Build the new connection string.** Same host, port, database and
   `sslmode=require` as today; only the user and password change.
   `sslmode` is not optional — libpq defaults to `prefer`, which
   silently falls back to plaintext on a failed handshake (AD-066).

2. **Prove it before trusting it.** With the new URL in a shell, not in
   a workflow:

   ```powershell
   $env:DATABASE_URL = "<new url>"
   python check_pipeline.py
   $env:REQUIRE_DB=1; pytest tests/test_db_privileges.py
   ```

   A pipeline that cannot write will say so here rather than at 06:55
   tomorrow.

3. **One workflow first.** Change `DATABASE_URL` in the GitHub secret
   for `ingest_tle` only, let it run once, and read
   `check_pipeline.py`. It is the highest-frequency job, so it fails
   fastest if something is wrong.

4. **Then the rest** — `ingest_visibility`, `propagate`,
   `enrich_catalog`, `monitor_catalog` — and the local `.env`.

5. **Only then**, rotate the `postgres` password, since anything still
   holding the old one will now break loudly instead of quietly
   continuing to work with too much privilege.

## Rollback

Put the old `DATABASE_URL` back. The role and its grants are inert
without a password, and nothing about the schema changed.

## What to watch for

**An UPDATE that matches zero rows is not an error.** Every table here
has RLS enabled, and `postgres` never noticed because a superuser
bypasses RLS entirely. A least-privilege role does not: with a GRANT but
no policy, INSERTs fail and UPDATEs quietly affect nothing — the
pipeline would report success while writing nothing.

019 creates an explicit policy per writable table for exactly this
reason. If you ever add a table the pipelines write, **it needs both a
grant and a policy**, and the way to find out is to become the role and
try, not to read the grant table.

## Open

- `check_grants.py` has no `--role` flag yet, so the verification block
  at the foot of 019 is a comment rather than a control that can go red.
  That is the next piece of this work.
