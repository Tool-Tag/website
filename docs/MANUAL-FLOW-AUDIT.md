# Manual pickup / production / delivery audit

Migration: `20261011062046_manual_flow_audit_guards.sql`. Forward-only; applied baselines and migrations, Agreement content and historical commercial snapshots are unchanged.

## Operational changes

- Customer tracking uses English and America/Denver formatting, compact expandable progress and Upcoming → Current → Completed route groups.
- A different address remains selected while empty. Customers can opt in to save additional addresses in private customer-linked storage; personal/company addresses are preserved.
- Status and driver routes listen for Supabase Realtime invalidations with a 20-second polling fallback. Arrival response clears the persistent five-minute wait; drivers see it without reloading.
- Pickup collection moves to Received at Shop. Staff compare every item with receiving photos and confirm each piece before any production action or pickup-route closure.
- Return departure requires per-stop item loading checks, finished work, resolved holds/extensions and either a zero balance or Cash. Second-attempt fees must already be paid. Initial departure notices do not include an ETA.
- Failed Return stops require shop verification of each undelivered item before route closure. A provisional, unpaid retry does not block confirmed stops in route sequence.
- Delivery photos are accepted only while Arrived. Receiving/delivery photo selection first displays the Spanish evidence warning. Camera and file choices are separate; payment proofs remain file-only.
- Cash handover uses the exact balance and existing payment receipt pipeline. Customer instructions explicitly prohibit overpayment and say tips are optional.
- Receipt acknowledgment is on customer tracking, after paid attended delivery; the driver acknowledgment modal and post-delivery payment link are removed.
- Return availability and auto-assignment cannot precede the pickup date. Delivery panels stay disabled after pickup until delivery details are ready, including jobs without a delivery leg.
- The existing worker adds dated payment-cutoff reminders 24 hours in advance, with schedule-specific dedupe keys. Existing notification records are not replayed.

## Realtime privacy

Realtime messages contain only `{}` and event `refresh`, never job rows, names, addresses, coordinates, payment data or tokens. Customer topics are capabilities derived from the existing 256+ bit random status token. The topic RPC validates the current token; every subsequent read/action also validates it. Revoking/replacing a token stops broadcasts to its old topic. Driver topics use a random per-route UUID, obtainable only by authorized staff. No anonymous SELECT on job/route tables and no broad Realtime RLS grants were introduced. Transport failures retain polling. Do not log capability topics.

## Verification

The isolated PostgreSQL fixture applies all six baselines and every forward migration. Regression coverage includes foreign-token denial, empty Realtime payloads, wait cancellation, per-piece shop/route gates, electronic versus Cash departure, failed-return closure, saved-address opt-in, future pickup bounds, cutoff deduplication and paid delivery → one customer receipt acknowledgment. No real customer email or payment is issued by these tests.

After publishing, apply this single migration with its exact timestamp and verify its history entry, functions, triggers, private tables, CI, production Vercel READY and the existing `tooltag-route-worker` schedule/run/HTTP result. Stripe configuration remains deferred.
