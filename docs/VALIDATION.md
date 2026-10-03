# Phase 1 validation

- Existing static regression suite: 25 tests passed (Falcon, time records, calculator, routes and localStorage preservation).
- Money and external adapter tests: 2 passed.
- PostgreSQL integration suite: 13 passed with the complete migrations, including role isolation, partial refunds, commercial revision, delivery evidence monthly worker idempotency and safe retries of financial requests.
- TypeScript, ESLint and production build passed during implementation; rerun after any follow-up edits.
- Browser smoke test used `tests/ui-fixture-server.mjs`: isolated PostgreSQL with a **test-only Auth/REST transport**. It is not a production integration and does not validate live Supabase Auth. No real customer or financial data was used.
- Browser tested: login, customer creation, quote creation, private quote view, quote acceptance, test agreement acceptance, automatic sale/job creation, full collection and Paid state.
- Responsive inspection: desktop and 390px mobile; found and corrected navigation/grid overflow (document width equals viewport width).
- Still required before production: real Auth/admin membership test, approved legal content and Vercel preview deployment. Drive/email/SMS remain intentionally unconnected.

Local browser fixture (never deploy it):

```sh
npm run test:ui-fixture
# in another terminal:
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54329 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=local-fixture-public-key npm run dev -- --port 3017
```

Test account: `admin@example.test` / `local-test-password`. These are fixed **local fixture values only**, not real credentials. Data disappears when the fixture process ends. The default `.env.local` always points to the user-provided Supabase project; test environment variables explicitly override it only for this command.

## Remote activation

Verified authenticated CLI points to boft-core (us-west-2), linked project eoldyqqupkuggyyfhqkg, and applied all nine migrations to the previously empty database. Live API checks reject anonymous customer access, unauthorized financial writes and invalid public links. No financial test records were created remotely. The Auth user table was empty; first-admin setup remains pending.
