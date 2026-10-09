# Local comparison prerequisites

These files are mechanically extracted from the actual remote pg_dump / pg_dumpall captures. They provide managed Auth/Storage infrastructure and role names for an isolated PostgreSQL 17 comparison environment. Install the real matching extensions first, including supabase_vault 0.3.1. Apply roles once on the local cluster; apply platform prerequisites to each new local database before the six candidate baselines. Retain the initial public schema. Do not apply these prerequisites to production. See docs/MIGRATION-BASELINE.md for scope and evidence.
