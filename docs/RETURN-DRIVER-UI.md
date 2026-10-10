# Return driver view — Block 3

Branch: feature/pick-return-ui. No production database changes are made by publishing this branch.

## Driver workflow

Daily Return routes include completed jobs with a delivery leg. Stops show customer, phone, address, pieces, Denver window and ETA. The attended handover sequence is Scheduled → En Route → Arrived → Delivered. Arrival sends one deduplicated notification and persists a five-minute countdown. A customer-coming response cancels that countdown permanently. At timeout, calling is optional; continuing records a miss. Delivery requires the customer present, payment collected/verified, and separate Delivery Evidence. Pending extensions, production holds and cancellation requests block handover. Additional work is closed one hour before the route window.

The driver can upload Delivery Evidence without leaving the route and present a simple receipt acknowledgment to the customer after handover. Receipt confirms delivery only, not payment or a waiver. Completing a stop starts the next eligible stop; closing the route still requires Confirm all delivered.

## Missed delivery

The first miss reserves the next available Sunday provisionally as a Requested/Pending stop. That reservation consumes route capacity but cannot start. No fee sale is created until the customer selects the second attempt. The second attempt costs the configured $10; verification of that payment confirms the reservation. Choosing shop pickup is free and releases the provisional stop. The first attempt remains nonrefundable.

An unpaid reservation is released at the one-hour route payment cutoff or after fifteen days, whichever comes first. The existing reconcile_delivery worker handles this. An uncollected retry fee is voided; the items remain for shop pickup. A second miss requires shop pickup, keeps the paid second fee nonrefundable and never creates a third trip.

## Deployment dependency

Apply the new additive migrations in order with the coordinated application deployment:

- 20261010082546_pickup_driver_arrival_flow.sql (Block 2)
- 20261010084023_return_driver_arrival_flow.sql (Block 3)

These files are not applied to production during this block. Applied baselines and historical migrations are unchanged. The existing route worker calls the replaced reconciliation function; no new cron or Stripe configuration is required.

## Validation

Typecheck, lint, automated tests and production build validate the branch. Database tests exercise arrival timing, presence/cash/evidence gates, receipt acknowledgment, pending extensions, holds, additional-work cutoff, retry confirmation/idempotency, shop release, fifteen-day expiry and the route payment cutoff. No customer emails or production records are created by these tests.
