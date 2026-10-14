# Shop Delivery blocks — audit handoff

Branch: `feature/pick-return-delivery-blocks`.
Base: `d48a6966c384bfc182e9478448b4b81e0e9edc84`.

## Approved scope

The shop schedules delivery jobs through **To Schedule → Routes → Returns → History**. The UI says **Pick Up / Delivery**; database leg `Return` is unchanged. New delivery scheduling requires the shop: completion, paid retry, final-payment cutoff and interrupted-driver reschedules enter To Schedule. Existing route assignments survive normal reconciliation.

The configured delivery weekdays remain unchanged. Every new block starts at 2 PM Denver and ends at 6 PM. This phase retains the existing unit/date/leg uniqueness constraint: one Block 1 per date. Numbered block fields and availability DTOs leave a clear extension point for a future multiple-block migration; this change does not offer extra blocks on a full date.

## Application changes

- `src/app/app/pick-return/page.tsx`: separates Pickup shop operations from Delivery, paginates existing records, sorts queue by the original production completion timestamp, supplies existing route/evidence records.
- `src/components/shop-delivery-board.tsx`: date/block assignment modal with no job/customer information; route cards and modal; explicit Edit/Save, driver selection, drag-and-drop with keyboard/mobile arrow alternatives, removal to queue; read-only failed-delivery monitoring; date-filtered history with existing evidence links.
- `src/app/delivery-block-actions.ts`: permission-checked server actions and revalidation.
- `src/app/status/[token]/page.tsx` and `src/components/return-choice.tsx`: retry choice remains available without an automatic reservation; customer copy explains shop scheduling after payment.
- `src/app/globals.css`: responsive block cards.
- `.github/workflows/ci.yml`: runs the existing verify gate on this audit branch without opening a PR.

Shop returned-item verification stays inside **Routes → block → Close block**. The existing per-item verification RPC and route-close guard are reused. Failed-stop evidence links are available beside the checklist. No evidence copies are created.

## Additive migration — not applied to production

`20261014024325_shop_delivery_blocks.sql`:

- Adds block number, default capacity 20, manual-order flag, and Owner capacity authorization metadata; adds a delivery-not-before date.
- Enforces capacity at the stop-write boundary with a locked route row. Every scheduling path is covered. Capacity above 20 requires an explicit Owner authorization reason and audit event.
- Adds permission-checked queue, availability, driver directory, assignment and atomic edit RPCs. Availability excludes full/closed/executing blocks and applies configured weekdays and the existing one-hour delivery cutoff.
- New blocks have no driver. The picker offers active users with Driver permission or Owner; historical operators retain their names in History.
- Explicit edits validate the complete current stop set before changing anything. Duplicate/foreign/stale stop IDs fail atomically. Executing/closed blocks cannot be edited.
- Default stop order is original completion time, then stable tie-breakers; explicit manual ordering remains stored. Cancelled stop records are retained, not deleted.
- Wraps existing automatic scheduling, retry reservation, reconciliation and driver-incident rescheduling while retaining existing payment, refund, cutoff and no-third-trip policies.
- Unpaid misses create a 15-day resolution deadline but no automatic future block. Payment moves the same Job to To Schedule; unpaid expiry moves it to free shop pickup and removes it from Returns. Original production completion priority is preserved.
- Keeps route/table RLS and authenticated-only mutations. Revokes direct access to renamed legacy public scheduling RPC.
- Changes generated notification copy only. No Agreement text, historical rows or applied migrations are rewritten.

`shop_delivery_blocks_enabled` defaults **true**. It is not exposed as a settings toggle. Existing legacy regression fixtures explicitly use false to continue testing their earlier behavior; the new tests exercise the production default true behavior.

## Verification

Disposable PGlite databases only: no production test records, customer emails or SMS.

New integration coverage: completion enters queue; existing assignments survive worker reconciliation; oldest-first assignment; atomic reorder/removal; stale/duplicate stop rejection; returned-piece closure gate; paid/unpaid retries; 15-day expiry; hard 20-stop limit across old/new RPCs; full-date exclusion; Owner-only capacity exception; cutoff and driver interruption requeue.

Verified locally: typecheck and lint passed; the complete suite passed 149 tests (33 adapter/source tests plus 116 core/logistics tests); production build passed. The build uses clearly fictitious public Supabase configuration, not production credentials.

## Publication boundary / resumption

Publish only this feature branch for audit. No PR, main merge or production migration is authorized in this task. After approval, application and this migration must be rolled out together; Delivery requires the new RPCs. Do not use a blind production `db push`: existing repository/remote history timestamps differ from previous connector applications.
