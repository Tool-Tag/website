# Customer route timeline — Block 6

Branch feature/pick-return-ui; no PR/merge or production changes.

Customer tracking /status/[token] now includes a mobile-first Spanish route timeline for Pickup and Return: Finalizadas / Actual / Próximas by numbered stop, highlights the customer's stop, route percentage, Denver-local route date/window/last update and ETA aprox. Existing 20-second visible-page polling refreshes it without a full reload. The work-stage timeline and tracking calendar are Spanish too; staff calendars remain English.

The read-only customer_route_tracking(job UUID, exact status token) RPC returns sanitized route positions/statuses and the owner's schedule/estimate. It never returns other job/customer identities, addresses, phone numbers, coordinates or tokens. Even staff membership alone cannot substitute for the exact status capability. It does not queue/replay notifications or mutate Jobs, payments or route states.

Route progress counts resolved stops (Completed/Failed/Cancelled) separately from successful handovers: failed attempts are explicitly labeled Intento sin completar. Cancelled other-customer stops are omitted. Provisional reservations are shown as pending. Closed routes require the existing operator confirmation. Latest noncancelled assignment per leg takes precedence over historical cancelled routes.

ETA reuses the existing system calculation: sequential straight-line travel at ~30 km/h + 15 minutes per remaining stop through the customer's stop. No Google Routes key or new travel integration is required. ETA is always labeled approximate, never guaranteed. No scheduled ETA is presented as a live estimate. It is hidden before departure, during an open incident, upon arrival/resolution, when location is missing, older than ten minutes, past, or predates a route stop mutation. The additive tracking_updated_at column/trigger invalidates an estimate when route information changes; driver location updates produce fresh estimates. No coordinates are exposed to the customer.

Additive migration 20261010173401_customer_route_tracking.sql is UNAPPLIED. Deploy after the earlier branch migrations; applied baselines and Agreement text remain unchanged. Tests verify secure anonymous access, foreign-token denial, privacy, no notification mutations, live/stale ETA, route changes/pauses and percentage/timeline completion. No real mail/refunds are sent in tests. Production activation and real-device validation after coordinated deployment remain pending.
