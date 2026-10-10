# Workflow v2 — Pick up & Return (Pt 3)

Branch: `feature/workflow-v2-pick-return`. Do not merge automatically.

## Acceptance coverage

| Criterion | Implementation |
| --- | --- |
| 1. Logistics payment proof | Optional Zelle/Venmo upload, “Recommend Upload Proof”, private payment-proofs object linked to payment request. |
| 2. Finish without full payment | Production trigger assigns Return and exposes Pending Delivery; customer payment reminder. |
| 3. 24h / 1h | Worker reconciles electronic verification, Cash selection cutoff and late payment route movement. |
| 4. Cash handover | Staff collection posts actual payment; delivery RPC rejects outstanding balance. Driver checklist includes recording tip. |
| 5. Stripe | Existing hosted Checkout/provider/webhook; disabled without configuration. |
| 6. Pickup window/cutoffs | Saturday 08:00–12:00 Denver; unpaid/late-confirmed 48h release and confirmed-but-unscheduled 24h movement. |
| 7. Calendar / ETA | Weekday restricted calendar and backend validation, 20-minute slots including 12 PM / 6 PM; no manual window end. |
| 8. Daily routes | Two landing modes, daily route list, sequential stop progression. |
| 9. Explicit closure / misses | Route confirmation required. First miss offers free shop or paid retry; retry schedules only when fee confirmed; second miss requires shop, no refund or third trip. |
| 10. Delivery after production | Automatic available Sunday assignment, shared ETAs and configurable default capacity 20; acceptance link generated only after actual paid handover. |
| 11. Time / refresh | America/Denver timestamps; visible-page polling refreshes server data without full page reload. |
| 12. Timeline | Expandable Done / Current / Upcoming, finished piece count, percentage and latest update. |
| 13. Proof proxy | Stable /app/proofpayment/[job-code], server-side Storage download; staff membership or matching private customer token required. |

The first $19.99 pickup+delivery service covers pickup and first Return. Retry fee defaults to $10 in unit settings, is a separate operational SALE, and never changes accepted Quote/Agreement snapshots. Free shop pickup voids an unpaid, unperformed retry fee; an already paid retry requires staff assistance before changing the choice. No new refunds are implemented.

## Migration and deployment

New additive migration: `20261010021434_route_scheduling_payment_gates.sql`. Existing applied migrations and Agreement text are unchanged. Production has NOT been changed by this work.

After review/merge, coordinate application deployment and applying this migration using the normal deployment process. Verify migration history/function existence rather than assuming repository presence means applied.

A five-minute worker is prepared in `scripts/sql/enable-route-worker.sql`, following Supabase pg_cron/pg_net/Vault scheduling. Activate ONLY after the migration and matching `/api/cron` deployment are available. Store these Vault secrets through the dashboard, never commit their values:

- `tooltag_worker_url`: the deployed HTTPS `/api/cron` endpoint.
- `tooltag_worker_secret`: the exact `CRON_SECRET` configured in Vercel.

The script schedules only the ToolTag worker; existing notification transport remains unchanged. Check cron execution results and HTTP response status after activation. Do not activate against the old deployment.

Stripe still requires existing Stripe environment configuration; no onboarding or new provider was added. Zelle/Venmo destinations remain settings-driven.

## Validation

The logistics integration suite now restores all active migrations, including Storage and Pt 3. Tests cover fee/payment preservation, inclusive slots, token authorization, private proofs, shared ETA capacity/full-day movement, 48h pickup release, 24h/1h Return rules, Cash collection idempotency, retry scheduling/payment/idempotency, second miss and explicit route closure.

Local disposable PostgreSQL restore was also checked. No real customer email or production test records were created.

An additional run of legacy `test:db` found seven failures: its old customer-review fixtures omit mandatory logistics, and document fixtures attempt obsolete Drive writes. Those older fixture failures are separate from the default CI suite and are not concealed here. The fixtures require a follow-up migration to current public APIs; original assertions should be retained.
