# Route notifications — Block 4

Branch: feature/pick-return-ui. No PR, merge or production database changes in this block.

## Departure

The driver explicitly marks Leaving the shop in either route view. The existing notification queue sends ToolTag is on the way to each confirmed, unresolved stop. Requested provisional/unpaid reservations are excluded. A separate departed_at timestamp avoids confusing automatic stop activation with departure. Route/stop keys prevent duplicate notices after repeated taps or requests.

## Three stops remaining

Completing a stop that leaves exactly three Scheduled/En Route/Arrived stops creates one Driver nearby: 3 stops remaining notice for each of those customers. Failed/cancelled/provisional stops do not count. A route-level marker prevents replay if subsequent scheduling changes return the count to three. Location updates never enqueue further copies. Already claimed/sent notification payloads are immutable.

## ETA aprox.

The driver enables browser location access (also requested after marking departure). While this screen stays open, position changes refresh estimates at most once every 45 seconds; location older than 90 seconds is not used when completing a stop. No background GPS guarantee is made for locked/background phones. Raw driver GPS is not persisted.

For each customer, follow the ordered remaining stops from the current driver position through that customer's stop. Sum haversine straight-line distances; travel minutes = km / 30 × 60. Add 15 minutes for each stop in that prefix (5 waiting + 10 processing). Thus three colocated remaining stops have conservative approximate ETAs of 15, 30 and 45 minutes. These are estimates, not fixed scheduled times. Scheduled ETAs remain unchanged; separate approximate ETA fields display in driver and public tracking.

No Google Routes key is needed. Existing addresses have no coordinates, so the server uses the public US Census geocoder and caches matched coordinates on each stop. It accepts only a single valid address match. Missing/ambiguous addresses, unavailable geocoder or missing GPS yield an unavailable estimate; later position updates can recover. After a missing intermediate stop, downstream estimates are also unavailable rather than skipping unknown travel distance.

The RouteTravelProvider interface separates travel estimation from notifications; a future Google Routes provider can replace simpleRouteTravel without changing events, UI or payment logic. Google is not configured or called. Census documentation: https://geocoding.geo.census.gov/geocoder/Geocoding_Services_API.html

## Deployment

New additive migration: 20261010085926_route_departure_proximity_notifications.sql. Apply after the Block 2/3 migrations during coordinated deployment. This block does not apply any migration to production or configure external credentials. All new RPCs require staff authorization for the route's unit; anonymous execution is revoked. Existing queue/sender configuration remains in use.

## Verification

Automated tests cover departure deduplication, both route legs at the three-stop threshold, recipients, no historical/sent message replay, ETA updates and missing data, staff-only RPCs, straight-line formula, inclusive processing time and geocoder failures/ambiguity. Local tests create no production records or real email.
