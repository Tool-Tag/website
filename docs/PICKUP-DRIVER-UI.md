# Pickup driver UI — blocks 1 / 2

Branch: feature/pick-return-ui. No PR or production database changes yet.

The Pickup daily view includes only confirmed-payment Pickup Only / Pickup & Delivery stops, with a scheduled Saturday matching the selected day. Driver controls enforce Scheduled → En Route → Arrived → Picked Up; photos use the existing private Receiving Evidence upload. Completion advances the next eligible stop and scrolls to it. Route closure still requires explicit arrival-at-shop confirmation.

New additive migration: 20261010082546_pickup_driver_arrival_flow.sql. Apply during the coordinated deployment after review; none of the applied migrations/baselines were changed.

Arrival sends the existing notification transport a deduplicated PICKUP_ARRIVED event. A server-owned five-minute deadline persists through reloads. Customer-coming stops the timer and locks Continue; Wait more starts five more minutes. The optional SMS button opens the device messaging composer (no automatic SMS provider or background text sending).

Continuing after timeout records a Failed pickup, leaves its confirmed fee unchanged and sends a customer status link. The customer can choose the next available Saturday at no additional cost, or use existing cancellation; the Failed pickup retains its nonrefundable logistics fee. Cancellation Requested / Production Hold gates are enforced on the server, including the older RPC. No Agreement text or accepted snapshot changes.

Tests cover timer gates, arrival notification deduplication, customer-coming persistence, restart, free rescheduling, hold enforcement and cancellation fee retention, in addition to the existing logistics suite. No production test records or live mail were used.
