> Audit publication authorized October 12, 2026: one combined commit on `feature/utah-sales-tax`, branch push only. No main merge or production migration is authorized. The local-only statements below record the implementation/validation stage before this publication.

# Utah sales tax — local review

Branch: `feature/utah-sales-tax`. Working tree only: no commit, push, deployment or production SQL.

## Behavior

Settings → Prices has an Owner-only tax rate, default **7.45%**, editable with up to three decimal places (0–100%). This is the supplied business rate; there is no automatic address/jurisdiction lookup.

Draft Quotes and draft/requested extensions follow rate changes. Sent/accepted records preserve their pinned rate. Existing sent/accepted Quotes and historical financial records retain their prior untaxed amounts; revise a sent Quote to apply the new rate rather than silently changing its price. The Customer Agreement text is untouched.

Tax = round(subtotal × rate / 100, 2), once on the subtotal including logistics. The stored total is the amount charged. Example: service $40 + logistics $19.99 = $59.99; tax $4.47; total $64.46. Fee-only payment = $19.99 + $1.49 = $21.48, with the remaining balance calculated from the full accepted total.

Shared breakdown/notice appears in Quote builder/details, customer Review & Accept, Quote email, accepted PDF, extension proposals and the completion/review/pickup/status payment views. Subtotal/tax/rate/total are frozen in commercial snapshots and sale versions. Mixed-rate consolidated Jobs display the rates explicitly.

Payments continue through existing manual verification, cash collection and Stripe TEST providers. Their requests/attempts and the ledger now receive the tax-inclusive amounts. Taxable second-trip balances are included in Card allocation, matching manual allocation. Extension pricing also fixes the existing ambiguous SQL assignment `total=total` discovered while testing this path.

Finance cash and receivables remain gross; operating revenue excludes the stored tax component. This does not implement tax filing/remittance or a full tax-payable ledger.

## Migration

New additive, forward-only file: `supabase/migrations/20261013001000_utah_sales_tax.sql`.

Adds settings/Quote/extension rates, logistics net fee/rate, sale/version tax snapshots, calculation triggers and token-scoped `public_payment_tax`. Preserves the existing intake/payment/RBAC architecture. Extends logistics constraints/locks to cover the tax metadata. Applied migrations and baselines are not edited.

Public payment breakdowns validate the existing capability token through the existing public Quote/completion/pickup/status authorization. Rate reads require Quote/Settings access; rate edits require Owner. Tax metadata on sales contains pricing only, not customer contact data.

Do not publish app changes until the additive migration has been reviewed and applied during the separately authorized rollout. No production migration was applied for this task.

## Validation

Local tests cover exact cent rounding, non-default/zero rates, tax-inclusive logistics/full attempts, rate pinning after send/accept, immutable acceptance, extension totals, second Return fee and net revenue. Existing tests use a zero-rate fixture to preserve their pre-tax expectations. All fixtures are local; no real customer payments or notifications are sent.

## Same local batch: Venmo

New additive configuration migration `20261013002000_tooltag_venmo_manual_payment.sql` sets only ToolTag's configurable `venmo_handle` to the confirmed `@boftbuild`. Account name is Bandits of the Framing. The completion, logistics, pickup and cancellation-balance payment forms share the exact approved legal-payee/memo disclaimer and a validated `https://venmo.com/boftbuild` link that opens a new tab with `noopener noreferrer`.

The existing manual provider and RPCs remain authoritative: Venmo stays pending verification until staff confirms it. No redirect, screenshot or external-link click marks it paid. The amount follows the tax-inclusive totals from the earlier migration. No Venmo OAuth/API/webhook integration is introduced; no payment was sent and no production setting was changed. Both migrations remain local for the single later commit/push.

## Same local batch: Refunds

New additive migration: `20261013003000_manual_job_refunds.sql`. Canonical UI: `/app/finance/refunds`; `/app/refunds` redirects there. Job detail has a Refunds tab for staff with `payments.refund` or `payments.view`. The former can create/confirm/complete/cancel; the latter is read-only. The shared navigation counter now counts the canonical Pending registry once, including manual, cancellation and route obligations.

`refund_requests` stores the required Job, amount ($5/$10/custom), reason, original/selected method, Pending/Completed/Cancelled state, issue event/date, report/request/confirmation/processing timestamps, staff IDs, proof, reference, notes, accounting period, cumulative processed amount and immutable last confirmation. Proof uploads use existing private Supabase Storage and secure authenticated document downloads. Each proof must match its refund, Job and unit. Electronic methods and Check are allowed; Cash/Other are rejected. Staff selects the actual disbursement account (defaults to the original payment account) so changing Cash to electronic does not silently debit the wrong account.

**Confirmed policy:** 14 calendar days from the event that caused the issue: Pickup, Return, Delivery or Completion notice. Staff selects that event; recorded timestamps are authoritative (completion uses the first successfully sent readiness/completion notice). If an event was not recorded in the app, staff captures its actual timestamp for audit. The reported date is separate from the request date. Calendar-day comparisons use America/Denver. The Agreement text is untouched.

Eligibility confirmation starts a 5–7 business-day window, Monday–Friday; weekends are excluded, holidays are not automatically modeled. Completion is blocked before business day 5; overdue completion remains possible rather than preventing a late refund. Staff manually issues the money outside ToolTag and records its reference/proof. No button initiates a bank/Stripe transfer. Pending requests reserve the paid balance; completion rechecks actual collections/refunds, including approved-sale payments, extensions and return-attempt fees. It cannot exceed funds actually paid.

Driver-down Wait creates one Pending $5 obligation immediately; Reschedule creates/upgrades it to $10, keyed by incident+Job. Already issued amounts are retained and only the remaining amount is processed; an upgrade restarts staff confirmation. Missing/ambiguous prior provider payment requires review. Both the application cron and database claim/finish paths stop automatic refund transfers. The old customer-refund entry points direct ToolTag staff to the canonical workflow, preventing proof/date bypass; BOFT cancellation processing and vendor refunds are retained.

Completion writes actual REFUND transactions allocated to original collections, generates a frozen Refund Receipt and queues one confirmation through the existing notification system with amount, date, method, Job/Quote and payment reference. Repeat completion returns the same snapshot, creating no additional ledger row or notification. Historical cancellation/route obligations are mirrored directly into the registry during migration; their operational rows, payment ledger and historical notifications are not replayed.

### Local validation and rollout state

All changes remain uncommitted in `feature/utah-sales-tax`, based on `7f81df16459f8f60bfcbf29142c91fbbec377533`, at `/private/tmp/tooltag-manual-audit`. No push, merge, deploy, real payment, real email/SMS or production SQL has occurred in this batch.

Future rollout requires separate authorization and review of the **three new migrations in order**: tax `20261013001000`, Venmo `20261013002000`, Refunds `20261013003000`. Applied migrations/baselines are unchanged. These migrations have only been exercised in the local PGlite fixture. Do not use a blind linked db push; existing remote/source history version differences still require a separately reviewed deployment plan.

The local test suite covers paid-balance reservations, business/calendar dates, authoritative event timestamps, original Cash handling, account selection, proof scoping, duplicate completion, immediate/unique driver obligations and inert worker, refund-only/read-only/driver RBAC, as well as migration backfill with unchanged transaction/notification counts. Tests use local records and mocked integrations exclusively.

Final verification (local batch): **typecheck passed; lint passed; npm test 139/139 passed (33 CJS + 106 TS); production build passed; git diff --check passed**. Build output includes `/app/finance/refunds`. Nothing was committed or pushed. No work remains for implementation in this batch; audit, one combined commit/push and production migration rollout await authorization.

Key Refund files: `src/app/app/finance/refunds/page.tsx`, `src/features/refunds.tsx`, `src/components/refund-forms.tsx`, `src/app/refund-actions.ts`, `supabase/migrations/20261013003000_manual_job_refunds.sql`. Integration changes: Job tabs, Finance tabs, evidence upload metadata/RBAC, manual movement form, attention counter and cron. Existing automatic-provider helper is no longer connected to the cron; its worker compatibility entry point is inert.

## Same local batch: SMS cost accounting (Phase 1)

New migration generated locally with the Supabase CLI: `20261013010948_sms_job_cost_accounting.sql` (fourth, after tax/Venmo/Refunds). No migration was applied remotely. Owner-only Settings → Notifications stores `sms_unit_cost`, default **$0.00645**, with eight-decimal precision and the actual SMS expense account. This does not activate SMS sending or change credentials/opt-in behavior.

**Martín's confirmed correction:** charge every AWS-accepted submission, including eventual delivery failures. AWS `MessageId` is the acceptance evidence. Sent in the existing dispatcher means API acceptance, **not delivery to a handset**. Provider IDs and notification IDs deduplicate the cost. Rejected/unsent requests without acceptance produce no accepted-send expense. An ambiguous network response without a MessageId is separately flagged as **unconfirmed acceptance**, pending reconciliation; it is never relabeled as rejected or delivered.

The per-send rate is frozen when the send is claimed; configuration changes affect future sends only. `private.sms_cost_usage` retains notification/provider IDs, originating Quote ID/code, flow, acceptance time, exact rate and delivery metadata. A commercial flow's Quote revisions share a cost total; creating its Job attaches the existing count/cost to that Job without duplicating it. An unconverted Quote expiry/deletion finalizes the cost when no other live revision continues the same flow. The immutable accounting snapshot includes original Quote/revision origins and the Job/code when available. Deleted operational records do not erase cost provenance.

Terminal Jobs (`Completed`, `Closed` work stage, also cancellation so costs do not remain stranded) generate an automatic EXPENSE with category **SMS**, paid by Business, against the configured account. Unconverted, finalized Quotes use `SMS-Quote-<quote code>`; Jobs use `SMS-JOB-<job code>`. Nothing is charged to the customer. Exact usage costs retain eight decimals; the ledger rounds the accumulated expense to cents, never each send. Late accepted SMS after closure post only any additional rounded amount. Zero/sub-cent totals that round to zero remain traceable without inventing a positive ledger transaction.

Creation is immediate on closure/accepted late-send, with retries via the existing `run_scheduled_tasks` cron entry point. Account/category/posting failures preserve the SMS acceptance and show a pending-posting error; accounting can retry without resending SMS. No extra cron or production activation occurred. Historical SMS already sent before the migration are not repriced or replayed; costing is prospective.

Monitoring stores delivered / delivery-failed / unknown delivery counts independently of the charge. API acceptance starts as unknown delivery. The service-role-only `record_sms_delivery_outcome` can annotate a known AWS ID, ignores older observations and never changes its price or creates another expense. **No CloudWatch reader, subscription or scheduler is implemented/activated in Phase 1**; carrier outcomes remain unknown unless observed. Phase 2 will reconcile CloudWatch status, parts and actual provider prices.

Finance now has `/app/finance/sms` and per-Quote/Job cost panels for `payments.view`. Each generated transaction shows a frozen SMS expense trace. Private usage/provider IDs are not exposed to customers or drivers; authenticated users have read-only access to aggregate costs only with Finance permissions. Owner is required for cost/account edits; only service credentials can annotate outcomes or reconcile postings.

Key files: `src/features/sms-costs.tsx`, `src/app/app/finance/sms/page.tsx`, `src/components/sms-expense-trace.tsx`, new migration. Existing settings/actions/permission checks, Quote/Job/Finance views, Finance tabs and dispatcher log terminology integrate it. No new AWS secrets/dependencies or live AWS requests were used for testing.

Final expanded-batch verification: **typecheck passed; lint passed; tests 144/144 passed (33 CJS + 111 TS); production build passed; diff whitespace check passed**. The build includes `/app/finance/sms`. Local tests cover AWS-accepted delivery failures remaining chargeable, delivery metadata not affecting charges, provider/notification deduplication, precision/rate snapshots, Quote→Job transfer, expiration/deletion trace, late-send deltas, account failure retry and Owner/Finance permissions. All runs used local PGlite/mocks; no live SNS calls.

Audit handoff: `feature/utah-sales-tax`, based on `7f81df16459f8f60bfcbf29142c91fbbec377533`. The user authorized one combined commit and push of this branch for review. No PR, main merge or production SQL is authorized. All four migrations remain unapplied in production; CloudWatch reconciliation remains Phase 2.
