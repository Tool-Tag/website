# Pickup / failed Delivery / Lost — audit handoff

Branch: `feature/pick-return-delivery-blocks`.
Base for this batch: `ce65116da810694de1359386ec293b8d866fb4ad`.
Local checkout: `/private/tmp/tooltag-delivery-redesign`.

## Confirmed behavior

- Failed deliveries leave the live block display and enter Delivery → Verification. Their original stop and route relationship is retained for audit and closure gating.
- Staff checks every returned item and confirms **Verified**. Verified entries remain non-clickable with neutral styling.
- Missing checks show the item and Job, with **Go back / Mark as lost**. A Lost report requires an explanation and records the missing item IDs, actual driver, reporter and original route.
- Lost is a separate top-level menu with a simple read-only Job/customer/driver list. Lost Jobs are removed from operational queues and cannot continue production or be assigned to routes. Historical financial and accepted-document records are retained.
- A documented loss allows the original block to close as an explicit exception. No fake item-return checks are created.
- Pick Up mirrors Delivery: **To Schedule / Routes / Missed / History**, driver selection, atomic drag/drop or arrow reordering, removal to queue, evidence hyperlinks and date-filtered history.
- Pickup window remains 8 AM–12 PM on configured pickup days. Default capacity is 20, with the same audited Owner exception gate as Delivery.
- Missed rows: Pickup Only blue; Pickup & Delivery red. Their service labels are also visible so color is not the only distinction.
- Reattempt fee uses Pickup Only pricing ($9.99 base) and the accepted tax rate, even for a combined job. The original logistics fee and accepted Quote/Agreement remain unchanged.
- One invoice per failed stop; manual and Stripe TEST payments allocate only to that retry invoice. Pending Stripe attempts are reused with the existing provider idempotency key.
- After payment confirmation the customer chooses the new date; the job enters To Schedule sorted by chosen date and then original Job creation time. The shop assigns the block. Legacy scheduling cannot bypass this step or the payment gate.
- After 15 days without a resolved/paid response: Pickup Only cancels with no pickup refund; Pickup & Delivery cancels and creates one Pending $9.99 gross refund of unused delivery in the EXISTING Refunds section.
- A paid retry counts as a customer response and is not silently cancelled while the customer chooses a date.
- Refund routing reuses the existing cancellation and refund registry. This batch adds no new Refund UI and no automatic payout/provider refund call. Detailed processing stays in the existing module for later definition.
- New customer-facing text is English. Generated missed-pickup notices no longer promise free rebooking. Agreement text is untouched.

## Files

New:
- `supabase/migrations/20261014040750_pickup_blocks_failed_verification_lost.sql`
- `src/app/failed-delivery-actions.ts`
- `src/components/failed-delivery-verification.tsx`
- `src/app/app/lost/page.tsx`
- this handoff

Modified: shop P&R page and block board/actions; Pickup/Delivery driver views; customer missed-pickup/calendar/payment/status flow; navigation/permissions; operational Jobs filtering/attention counters; styling; integration tests.

## Database/security

Additive migration only. New registers have explicit authenticated SELECT grants and unit/permission RLS; writes use permission-checked audited RPCs with empty search paths. Private helpers and legacy bypass RPCs are not public-callable.

New retry invoices participate in the existing commercial totals, payment allocation, tax snapshots and refundable-payment trace. The 15-day worker wrapper is ToolTag-only, idempotent, and creates refund obligations without transferring money. Historical notification queues are not replayed. Old missed pickups without the new deadline are not retrospectively auto-expired.

Only the new migration is changed in this batch. Existing applied migrations, baselines, Agreement template, production DNS/configuration and production records are unchanged.

Rollout requires approval: the prior `20261014024325_shop_delivery_blocks.sql` and this new migration must be applied in order with the matching application code. Neither has been applied by this task. Do not use a blind `db push`: repository/remote history timestamps from earlier connector applications differ.

## Validation

Disposable PGlite only; no real customer email/SMS or external Stripe charge.

156 automated tests (33 CJS +123 core/logistics), including:
- all-item verification and block closure gate;
- documented Lost exception without fabricated item checks;
- Pickup block editing and preserved window;
- paid retry invoice allocation and legacy payment-gate bypass rejection;
- pinned Utah tax and Stripe TEST invoice allocation/attempt reuse;
- customer date choice → shop queue, without automatic route allocation;
- combined-job 15-day cancellation + one existing refund entry;
- Pickup Only 15-day cancellation, retained fee and no refund.

Typecheck, lint and production build are verified before publication. The build uses fictitious public Supabase configuration, never production secrets. Branch-only publication for audit; no PR, main merge or production migration in this task.
