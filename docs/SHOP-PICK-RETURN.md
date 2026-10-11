# Shop Pick up & Return

The workspace entry `/app/pick-return` is a shop dashboard, separate from the `/pick-return` driver interface. Its navigation and the workspace topbar open the shop view; the driver remains accessible through a clearly labeled link.

## Operations

- Receiving / Verification: collected pickups with unverified physical pieces. Show Receiving Evidence beside per-piece confirmations. Existing `verify_shop_item` requires evidence, admin authorization, and all pieces before production unlocks.
- Returned items: failed Return stops on open routes. Shop compares physical pieces with evidence and persists `Returned` checks through `verify_route_items`. Closing uses `confirm_pick_return_route`, which rejects unresolved stops or missing per-piece checks.
- Routes: date-based Pickup and Return lists, stop sequence, status, ETA, completion count, pre-departure loading checklist and shop arrival confirmation. Execute links open the existing driver route; no parallel route state machine is introduced.
- Pending / 15 days: active provisional second-attempt reservations and unresolved shop collections. Show the exact existing reservation deadline. The existing worker retains its route cutoff/15-day release policy. Do not reset deadlines or charge again. Shop handover uses the existing paid-handover guard.
- Re Scheduled: separate Pickup and Delivery cards. Unscheduled eligible jobs use the existing configurable-day calendar, payment gates, capacity and cutoff checks. Missed pickups await the customer's existing reschedule/cancel choice rather than choosing for them.

## Review decisions

No separate normative shop specification was available in the referenced attachments. The following reasonable defaults implement Martin's latest module description:

1. “Pending 15 days” uses the existing second-Return reservation expiry, not a new 15-day clock for every job. Free shop collection remains visible after reservation release until handover.
2. “Re Scheduled” means operational cases awaiting scheduling, including unassigned ready deliveries. Already scheduled jobs remain under Routes; reschedule them through the Job's existing controls.
3. Verification is restricted to the existing admin/shop permission. Drivers do not gain new rights. Existing backend guards remain authoritative even if the shop UI is stale.
4. Receiving evidence is reused; no new evidence category or duplicate file upload is created.
5. Route execution remains the driver interface, while physical receipt and returned-item verification are accessible from the shop dashboard.

All data is scoped to ToolTag through the authenticated RLS client. Operational datasets are paginated rather than silently capped at 200 records. Route invalidation uses existing private capability topics with the existing polling fallback. No migration, Agreement edit, payment-provider change or notification replay is required.
