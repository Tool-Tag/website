# Phase 1 implementation plan

1. Preserve `dist` byte-for-byte; serve it alongside Next.js through build-time copying and explicit rewrites. Application namespace: `/app`; public customer capabilities: `/accept`.
2. Version PostgreSQL schema and all business mutations. RLS scoped to unit membership. No direct authenticated table writes; constrained RPCs own atomic operations and audit.
3. Establish shared finance and immutable commercial revisions. One sale transaction; collections only affect cash. One inter-unit transfer with two allocation effects, zero physical cash effect.
4. Implement auth, customers, quotes/acceptance, jobs, finance, equipment and review pages. Keep missing external integrations explicit.
5. Execute SQL integration tests (including permissions and concurrency invariants), domain tests, existing static regression tests, typecheck, lint and production build. Inspect desktop/mobile.
6. Apply remote migrations only after verified boft-core authentication; never touch BOFT production.
