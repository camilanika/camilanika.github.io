# Automated tests

Not part of the website: nothing in this folder is loaded by the shop or admin pages.

| Suite | What it checks | Command |
|---|---|---|
| `unit/` | `js/cashflow-core.js`: WIB date presets, Rupiah parsing, form previews and validation | `npm run test:unit` |
| `db/run.sh` | Builds a fresh database from `supabase/schema.sql`, `seed.sql` and every migration, then runs `db/cashflow_test.sql` (totals, real/mock, offline orders, expenses, menu sales, filters, permissions) | `npm run test:db` |
| `db/backfill_test.sh` | Migration 014 on a database that already has orders, and running it twice | (part of `test:db`) |
| `ui/` | Chromium drives `admin.html#cashflow` against a real local database (forms, confirmations, totals, phone layout) | `npm run test:ui` |

## Setup
- Node 20+, PostgreSQL 16+ (`psql` on the PATH), and Playwright's Chromium.
- `db/supabase_stub.sql` stands in for the Supabase parts the scripts need (auth.users, auth.uid(), roles, storage).
- Start a throwaway PostgreSQL and point the tests at it, e.g.
  ```bash
  initdb -D /tmp/pg/data -A trust && pg_ctl -D /tmp/pg/data -o "-k /tmp/pg -p 5433" -l /tmp/pg/log start
  cd tests && npm install && PGHOST=/tmp/pg PGPORT=5433 npm test
  ```
- The tests create and drop the databases `cn_test`, `cn_backfill` and `cn_ui`. Never point them at the live Supabase database.
