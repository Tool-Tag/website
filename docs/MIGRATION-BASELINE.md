# Migration baseline — stage 1

Completed 2026-10-09. Canonical source: production boft-core (`eoldyqqupkuggyyfhqkg`), PostgreSQL 17.11. Production access was read-only throughout.

## Working tree and scope

Work was performed in a fresh origin/main clone at `/tmp/tooltag-baseline-stage1/website-clean`, based on `eebd7fa56cc4385c193d802f24114e855eb3991d`. The stale, dirty original checkout was not modified. No commit, push, deployment, production reset, db push or migration repair was performed. The existing 76 files under `supabase/migrations` remain unchanged.

The six candidates are deliberately outside the active migration directory, under `supabase/baseline-stage1`. Activation and migration-history repair belong to a separately approved stage 2.

## Provenance and partition

Actual PostgreSQL 17.11 tools produced:

- `pg_dump --schema-only`: full remote schema, including managed prerequisites.
- `pg_dump --schema-only --schema=public --schema=private`: application schema.
- `pg_dump --data-only` with explicit bootstrap tables: business_units, categories, unit_settings, accounts, physical_accounts, policies, storage.buckets.
- `pg_dumpall --roles-only --no-role-passwords`: role definitions.

Remote connections used `default_transaction_read_only=on`. Connection credentials were read from the original ignored `.env.baseline.local`, passed through process environment and never copied into this checkout or command arguments. Raw captures and the 58-row migration-history backup are retained in ignored `supabase/baseline-stage1-inputs/`.

`tools/migration-baseline/partition.py` partitions intact dump object blocks mechanically. The manifest records input SHA256, source ordinal, object identity, domain and block SHA256. No handwritten baseline DDL, rewritten routine bodies or handwritten bootstrap inserts were introduced.

1. Core: infrastructure/helpers and foundational relations.
2. Finance: accounts, transactions, payments, collections and reporting.
3. Commercial: customers, quotes, pricing, Agreements and accepted documents.
4. Operations: Get Tagged and operational workflow.
5. Integrations: mail/notification routines and relations.
6. Security/bootstrap: views, constraints, indexes, triggers, policies, privileges and exact bootstrap COPY data.

All 831 application dump blocks are accounted for exactly once. Two blocks describe the platform-provided public schema/comment and are preserved in the source manifest rather than re-created; clean PostgreSQL already supplies this schema and its default PUBLIC USAGE. The other 829 blocks, plus one project Storage policy, appear in the candidates. Cross-domain post-data objects are finalized in candidate 6. Dump function-body checking settings are preserved.

Managed Auth/Storage infrastructure, roles and extension prerequisites are mechanically extracted separately for the clean comparison environment. They are not an attempt to replace Supabase-managed production infrastructure. All five remote extensions were available locally; the real official supabase_vault 0.3.1 was compiled, with libsodium 1.0.20, instead of using a mock extension.

## Comparison results

A new local database was restored from platform prerequisites and candidates 1–6. The comparison database contains no customer/auth-user/quote/job/sale/collection/notification/acceptance history. Bootstrap has 31 rows across seven tables, including the exact two legal templates; no live user records or Vault secrets were copied.

| Check | Result |
| --- | --- |
| Normalized application pg_dump schema diff | Empty, 0 bytes |
| Remote/local normalized SHA256 | `19b510dc0cf682b949b5cfb7c62ffc2c7ac6f48278ce7cc363dec48b6cf330c2` |
| Independent catalog fingerprints | All 12 categories identical |
| Bootstrap data fingerprints | All seven tables identical |
| Remote migration history | All 58 rows unchanged |
| Database tests | 21 passed, 0 failed |
| Other automated tests | 30 passed, 0 failed |
| Typecheck / lint | Passed |

The independent catalog includes 67 relations, 619 columns, 326 constraints, 153 indexes, 148 functions, 58 triggers, 46 policies (including Storage), 256 routine grants, 844 relation grants, 72 default privilege entries, two application schemas and five extensions. OIDs are excluded. This is an application-schema comparison plus the project Storage policy and extension inventory, not a claim that every Supabase-managed internal schema was independently compared.

The normalized dump comparison removes client restrict tokens/header/footer and sorts object blocks; object definitions are not rewritten. A separate catalog fingerprint prevents relying only on the partition source.

Exact bootstrap text was checked independently. COPY format was required to preserve legal-template CRLF bytes; the final seven table fingerprints match, including those templates.

Evidence: `docs/baseline-stage1-evidence/` contains schema, catalog, bootstrap, history and clean-row comparisons plus verification logs. `manifest.json` contains source provenance.

## Test harness

`BASELINE_DATABASE_URL` enables the PostgreSQL baseline test adapter. It rejects non-local hosts and creates/drops a separate disposable database for each database test file; it never uses the canonical comparison database for fixture mutations. Existing PGlite coverage remains available without that environment variable, including the legacy upgrade test.

Fixtures were aligned to existing production requirements: engraving locations, separate $5 additional-engraving pricing, current evidence workflow and published-Agreement prerequisites. Only disposable test databases remove seeded policies for the explicit no-published-Agreement test. Baseline SQL and production were not changed to satisfy fixtures.

Re-run the tested database suite while the local server and tools remain available:

```sh
BASELINE_PG_BIN=/tmp/tooltag-baseline-stage1/pg17-tools/bin BASELINE_DATABASE_URL=postgresql://postgres@127.0.0.1:55439/postgres npm run test:db
```

Regenerate candidates from retained raw captures (now writes to supabase/baseline-stage1-candidates; original raw captures remain in the stage-1 checkout):

```sh
python3 tools/migration-baseline/partition.py --dump-dir supabase/baseline-stage1-inputs --repository .
```

For a fresh PostgreSQL 17 comparison environment, install the matching extensions, restore `supabase/baseline-stage1-support/roles.sql` once as local superuser, create a new empty local database (retain its default public schema), restore `platform-prerequisites.sql`, then apply the six candidate SQL files in numeric order using psql with ON_ERROR_STOP. Never direct this restore procedure at production. Run `fingerprint.sql` independently against each database and compare canonical JSON; run `normalize_schema.py` on independently generated schema-only dumps.

## Stage 2 is not authorized

The 76-file historical migration chain is still active. Remote history remains 58 rows (57 common entries; 19 local-only entries; remote-only `20261008052657`). The candidates are verified review artifacts only. Do not move them into the active folder, archive the chain, repair history or deploy them until separate approval of stage 2 and review of these results.

## Stage 2 — local activation

The 76 historical SQL files are archived byte-for-byte under `supabase/migrations-archive/pre-baseline`. The six active files under `supabase/migrations` were named by the CLI in order and contain unchanged stage-1 SQL. Active names/hashes are recorded in `docs/baseline-stage1-evidence/manifest.json`. The local PostgreSQL adapter reads active migrations; historical PGlite/legacy coverage reads the archive. Generator output is now a separate candidate directory. No production repair has been executed. The earlier stage-1 status above describes that completed stage, not current active-file placement.

Stage-2 local verification: 21/21 database tests using the six active migrations; 30/30 other automated tests; typecheck, application lint and targeted database-test lint passed. Historical files and active baseline contents were compared byte-for-byte to stage 1. Remote operations remain pending separate approval.
