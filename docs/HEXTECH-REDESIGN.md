# ToolTag Hextech UI

This change applies ToolTag's original hexagonal/bracket styling to the public site, workspace and driver screens. It does not add or alter migrations, database states, pricing, payment rules, notifications, RLS or Agreement text.

## Shared UI

- `public/hextech.css` is shared by the static public pages and the Next application. Palette: gold #d9b366, blue accent #3177ff, muted action blue #2453a6, background #0B0D0F and secondary gray #A7ADB5.
- Traffic-light colors remain reserved for Support, Refund and Lost urgency. Other counters/statuses use neutral, gold or blue treatments.
- `HexModalFrame` separates a fixed header, one scrolling body and a fixed action footer. `ModalActions` portals existing controls into that footer and preserves native form association. Per-row edit controls remain attached to their own rows.
- Native dialogs remain viewport anchored when opened far down a page. Existing ModalClose/DialogClose controls retain their handlers and render as exterior beveled gold rectangles, with reserved viewport gutters.
- Mobile table cells get their desktop column labels; tapping an actionable row invokes its existing action. Modified clicks, interactive children and text selection are preserved. Pagination remains outside list panels with Gold Previous/Next controls.
- English is the default UI. The approved Policies and Conditions Español toggle is the intentional exception; its legal text is unchanged.

## Get Tagged

Three steps reuse the existing form, validation, session draft, photo normalization and submission endpoint. Next validates the current step; Submit validates the complete request. Distinct Next/Submit button keys prevent the transition to step three from submitting accidentally. Optional preferred day is appended to existing notes as an unconfirmed request, never treated as a scheduled reservation. Camera/file selection, drop, preview and removal are available for optional tool photos.

## Shop Floor

New read-only `/app/shop-floor` uses existing permission/session checks and the authenticated, unit-scoped database client. Stable API paging avoids the default row cap. All five visual groups sort by full arrival timestamp, then code/ID:

| Visual stage | Existing state |
| --- | --- |
| Reception | Not Started / Receiving Evidence |
| Verification | Received at Shop |
| Falcon Queue | Preparing |
| In Process | Engraving / Final Evidence / Final Details |
| Ready for pickup/delivery | Ready for Delivery / Delivery In Progress |

Arrival is derived from existing item receiving timestamps or confirmed pickup route timestamps. Missing arrival is explicitly labeled and falls back to the job creation timestamp for sorting. Cards open full item/notes details and link to the existing job action; no new production transition is introduced.

## Driver

Existing route data/actions now appear as compact stop cards, a segmented progress strip, next-stop emphasis, a bottom navigation bar and stop-detail dialogs. Evidence retains its existing storage/actions. Camera controls are restored only here and in Get Tagged; other uploaders retain a standard file input. Photo reminders appear after a completion attempt without evidence; existing server evidence/payment/presence gates remain authoritative. Delivery confirmation is required before the existing completion action.

## Validation

- Local typecheck, lint, test suite and production build.
- Browser checks at 320px, 390px and 1280px: table cards/labels, two-column Shop Floor grid, exterior X bounds, fixed modal header/footer, a real native required-field form submitted through the portaled footer, driver payment controls, Get Tagged step transitions and no premature submission.
- Production schema inspected read-only: all seven Shop Floor source tables and their required fields exist, with RLS enabled. No production writes or customer notifications were performed.
- Local visual fixtures were removed before commit. Their screenshots contain synthetic TEST labels only.
- Real camera hardware, authenticated role-by-role production navigation and live storage submissions were not exercised. Review the Vercel preview on a phone before approval.
