# Automated tests

Not part of the website: nothing in this folder is loaded by the shop or admin pages.

| Suite | What it checks | Command |
|---|---|---|
| `unit/` | `js/cashflow-core.js`: WIB date presets, Rupiah parsing, form previews and validation | `npm run test:unit` |
| `db/run.sh` | Builds a fresh database from `supabase/schema.sql`, `seed.sql` and every migration, then runs `db/cashflow_test.sql` (totals, real/mock, offline orders, expenses, menu sales, filters, permissions) | `npm run test:db` |
| `db/backfill_test.sh` | Migration 014 on a database that already has orders, and running it twice | (part of `test:db`) |
| `db/security_test.sql` | Permissions and money rules: RLS on every table, internal functions closed to API users, every admin RPC refuses customers, server-side prices, idempotent payment | (part of `test:db`) |
| `db/qa_fixes_test.sql` | Regression tests for the defects fixed by migration 017 (QA inspection, 8 Nov 2026), plus a check that migration 014 refuses to re-run on its own | (part of `test:db`) |
| `db/known_defects_test.sql` | Executable bug reports for defects that are still open; reports STILL PRESENT / FIXED and never fails | `npm run test:known-defects` |
| `ui/` | Chromium drives the shop and `admin.html` against a real local database (Cashflow, checkout and payment return, admin forms, accessibility checks, phone layout) | `npm run test:ui` |

## Setup
- Node 20+, PostgreSQL 16+ (`psql` on the PATH), and Playwright's Chromium (`npm install`, then `npx playwright install chromium`).
- `db/supabase_stub.sql` stands in for the Supabase parts the scripts need (auth.users, auth.uid(), roles, storage).
- Start a throwaway PostgreSQL and point the tests at it, e.g.
  ```bash
  initdb -D /tmp/pg/data -A trust && pg_ctl -D /tmp/pg/data -o "-k /tmp/pg -p 5433" -l /tmp/pg/log start
  cd tests && npm install && PGHOST=/tmp/pg PGPORT=5433 npm test
  ```
- The tests create and drop the databases `cn_test`, `cn_backfill`, `cn_ui` and `cn_defects`. Never point them at the live Supabase database.
