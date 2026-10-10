# Driver route exceptions — Block 5

Branch: feature/pick-return-ui. No PR/merge or production database changes in this block.

## Existing misses preserved

Missed Pickup remains a customer choice: next available Saturday at no extra charge or cancellation, retaining the nonrefundable Pickup fee. Missed Return retains the Block 3 provisional Sunday / paid $10 retry / free shop alternative and second-miss rules. A driver interruption never increments customer miss counters or creates second-attempt fees. Customer Agreement text is untouched.

## Operator interruption

Large route controls report Driver unavailable. This snapshots only remaining confirmed stops, sends one apology per job and pauses advancement/handover. Provisional unpaid reservations and already resolved stops are excluded. The operator has fifteen minutes to confirm replacement, rescheduling or no replacement. Deadline is stored server-side; late confirmation cannot continue the old route. UI timer and the existing worker both resolve expiration to Rescheduled with $10 compensation terms. The worker runs on its existing cadence; deadline enforcement is exact in RPCs, notifications without an open app occur on the next worker tick.

Replacement: route continues with an approximately one-hour delay and $5 compensation per waiting job. Wait is the default while the operator confirms; customers can request next route day from their secure status link. Reschedule: next available Saturday for Pickup / Sunday for Return, free, $10 compensation per job. If a customer switches after $5 was already issued, only the remaining $5 is due, never $15 total.

No replacement: Pickup moves to the next available Saturday free with $10 compensation, never asks the customer to bring pieces to the shop. Return cancels that trip, holds items for free shop pickup and owes $10 compensation. Nothing is left unattended. Interrupted route closure is explicit; partially collected Pickups still require shop-arrival confirmation.

## Actual refunds and limits

Compensation is recorded automatically as due; money is not labeled issued merely because a route decision exists. The refund links to an actual original COLLECTION and uses its payment method. Insufficient/unallocated payments require review rather than refunding more than the original collection. The staff Refunds screen and counter include route compensations; customer tracking shows due/issued/status.

Stripe transport is implemented but NOT activated: STRIPE_SECRET_KEY remains unconfigured. It retrieves the original Checkout payment intent, checks existing refunds by durable part metadata before creating one, uses an idempotency key, validates amount/currency/payment intent, and records a REFUND ledger transaction only when Stripe reports succeeded. Pending/failure/network/ledger outcomes do not become paid. Leases and immutable refund parts make retries and $5 → $10 upgrades reproducible. Claimed/sent notifications are not replayed.

The currently connected Zelle/Venmo adapters are manual payment adapters, and Cash has no API refund transport. These methods therefore remain ManualRequired with a clearly visible actual-refund confirmation/reference in the staff Refunds view. They cannot be made automatic by application code alone: a real provider/bank integration supporting refunds is required. No fake automatic reimbursement is recorded.

## Configuration / deployment

Additive migration: 20261010163601_driver_route_exception_flow.sql, UNAPPLIED to production. Apply after Block 2–4 migrations during coordinated deployment. It extends run_scheduled_tasks to reconcile incident deadlines; /api/cron additionally processes eligible refund parts. Existing cron authorization stays unchanged. BOFT and applied migration files remain untouched.

Automatic card refunds require the original account's STRIPE_SECRET_KEY and TOOLTAG_REFUND_MODE=live in Vercel production (VERCEL_ENV=production supplied by Vercel). Default is disabled. Tests may set mode=test only outside production with sk_test keys. No secrets are committed and no external credentials or production settings are configured in this block.

Verification: typecheck, lint, automated tests and production build. Tests cover route pause, operator timeout with no user auth, free rescheduling on the correct weekday, Return shop fallback, secure customer choices, notification/compensation deduplication, manual original-method proof, Stripe gating and durable retries, pending ≠ paid, and $5 → $10 differential refunds. Tests send no real email or refunds.

Stripe reference: https://docs.stripe.com/api/refunds/create

## Configurable delivery weekday
Additive migration 20261010165438_configurable_delivery_route_day.sql (unapplied) adds unit_settings.delivery_route_iso_weekday: ISO 1=Monday through 7=Sunday, default 7. The admin Settings → Payments & Logistics → Delivery Route Day selector (authorized save_settings RPC) changes the weekly day used by availability, new/retry/interrupted delivery scheduling, customer calendar and driver landing. Pickup stays Saturday. The Return window remains 2–6 PM, including the final slot. Existing stops are not moved; no historical data is migrated. Notifications say “next available delivery route day” and scheduling messages include the actual selected date. No production setting was changed.
