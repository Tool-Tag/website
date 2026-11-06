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

## November 4 — alignment to supplied visual references

Martin supplied two standalone HTML references (Tooltag App Sample Hextech and Tooltag Public Page Hextech example). The first pass was too generic. This follow-up maps their actual visual system onto the existing ToolTag components:

- Self-hosted Barlow body text, Rajdhani app headings/navigation, Oswald public headings and Barlow Condensed labels. Font files and upstream SIL Open Font Licenses are in `public/fonts`; no runtime Google Fonts request or build-time font download is required.
- `hextech-reference.css` adapts the app reference's dark grid, 264px grouped navigation, hex icons, chamfered metric cards/buttons, thin table rules, four gold corner brackets, typography and modal framing. Existing utilities/search/name/Sign Out remain available. The desktop menu toggle collapses navigation locally; the mobile drawer uses the same permission-filtered links.
- `hextech-public.css` and the public homepage adopt the supplied public composition: bracketed hero, blue emphasized heading, gear icons/cards, mark chips, connected process nodes, service options and CTA/footer. Real branding, `/help`, `/privacy`, `/terms`, original gallery IDs/data and all three real `/get-tagged` entry links are retained. The existing iframe/form submission still handles requests.
- Lost displays the actual case UUID prefix (full UUID on hover), job, customer, missing-item summary, reported time and status. Lost/Support selector tabs follow the reference blue selection; logistics retains its gold leg indicator. No case numbering or workflow rules changed.
- Modal positioning measures the rendered X so the reference's complete 42px control stays outside the panel even on narrow screens. A regression check covers 320/390/768px bounds. Native form validation and submission through a fixed footer were checked in the browser.
- Public intake now has an explicit responsive page container and form spacing, with the same real wizard, validation, optional photo upload and existing consent fields. Upload/Take photo controls use the existing handlers; other uploader rules are unchanged.

Intentional differences from the demo: no fake metrics, demo shortcuts, test customer content, demo notification bell, sample storage, mock form submission or new business logic were copied. Existing real data and permission gates remain authoritative. The approved muted action blue is retained; #3177ff stays an accent. The customer Agreement and the approved Spanish driver-policy exception remain untouched.

Visual review uses local temporary fixtures of the real components and the real public/intake routes. Temporary fixtures are removed before commit. No production data, payments, file uploads or customer messages are created during visual checks. Authenticated production role-by-role review and a physical phone camera remain outside these local checks.

Follow-up validation: typecheck, lint (zero warnings), 216 tests (38 CommonJS + 178 TypeScript) and webpack production build passed. Browser checks covered 320/390/1280 px, full-height drawer, desktop collapse, responsive table/cards, the 42px exterior X, native required-field submission through the fixed footer, and Get Tagged steps 1–3 without final submission. All source changes are visual; database migrations, server business actions and dependencies are unchanged.


## November 4 — app reference structure

The app sample now also guides composition, beyond its colors and typography:

- One compact 60px header: navigation toggle, ToolTag branding, real customer search, permission-filtered attention queues and user account menu. Utility links move into the grouped sidebar/drawer. Existing logout, four-hour session and login attention behavior remain intact. Desktop navigation can collapse; mobile uses the drawer.
- Dashboard hierarchy: four permission-filtered metrics (active jobs, new requests, next pickup block stops, collected this week), daily Support/Refund/Lost urgency bands and quick actions. Existing operational attention, financial details and activity remain accessible in disclosures. No sample metrics or hardcoded counts are used. Weekly collection reporting uses existing transactions and Denver calendar boundaries, without changing accounting or scheduling.
- Requests and Quotes use compact icon rows opening a read-only summary modal. Its action continues into the existing review/detail workflow. Existing tabs, pagination and permissions remain in place.
- Lost uses one tabs/list panel and a metadata grid in the case modal. Existing Notify/Approve/Process actions use the fixed footer; their handlers, workflow and rules are unchanged.
- Pick Up and Delivery keeps the existing leg/subtab controls in a single panel and renders route/history blocks as compact rows. Stop assignment, ordering, verification and closure actions remain unchanged.
- Settings retains its five Owner-only sections. Configuration groups open the existing forms in compact row-triggered dialogs; the existing ActionModal save/refresh context is preserved. Users/roles retains its dedicated management UI; no demo toggles or security/configuration rules were invented.
- Support modal prioritizes subject, customer and job details; its existing reply/closure actions are unchanged. Record Transaction adds two convenience selectors for existing Expense/Collection types, retaining the full type selector and receipt gates.

Local visual checks use synthetic props only, without database writes, message delivery, uploads or financial submissions. Checked desktop and 390/320px navigation, account menu, record summary modal, exterior X, Settings dialog and transaction type/proof controls. Temporary visual fixtures are removed from the committed application. Actual phone hardware and a live authenticated end-to-end test remain for review; these checks do not claim to validate those integrations.

Structure validation: typecheck, lint (zero warnings), and 218 tests (38 CommonJS + 180 TypeScript) passed. Production build uses non-secret placeholder public Supabase values, as the checkout intentionally has no live credentials; no live integration test is claimed.


## November 5 — remaining workflow screens (this round)

- Full-width desktop tables now use the available wrapper width and a fixed column layout; the shared Table supplies explicit columns. Raw tables receive the same width rules. Mobile keeps labeled cards without horizontal scrolling. Browser measurement confirmed table width equals wrapper width and a zero gap after the final header cell.
- Shop Floor has explicit all-stage sections and a distinct filtered grid, with two columns on phones. Both modes use the same `shopFloorGroups` full-timestamp ordering. Cards show arrival date/time in Denver, customer, piece counts, progress and one action; complete items/notes stay in the modal. No new persisted stages or transitions.
- Public Get Tagged now has a structural three-part wizard layout: fixed hex step indicator, one scrolling step body and fixed Back/Next/Submit footer inside the customer modal iframe. Removed duplicate iframe/root scrolling. All contact/consent, engraving, photo and service fields, validation and submission remain. Removed customer-wizard shortcuts from staff Requests and Dashboard; staff review is not a wizard.
- Driver route selection uses a dedicated presentation component populated by the existing server-scoped dates/counts, not mock values. Bracketed date selector, pickup-blue/delivery-gold route cards and shared ToolTag branding match the reference design system.
- Both live driver routes now use the same date/window header, completion count, segmented progress, highlighted next/current stop and connected hex-node timeline. Stop rows show existing address, piece count, status and ETA when available. Existing arrival/photo/payment/confirmation controls remain inside their detail dialogs, and existing bottom navigation remains. No route state transitions or notifications changed.
- ModalClose portals its button directly into the containing dialog, keeping it outside clipped/scrolling content and within the native dialog's focus/top layer. Fixed header/body/footer framing no longer creates an extra frame for each nested form: its ModalActions use the containing modal footer with the existing native form association.

Visual validation: desktop table geometry; Shop Floor five sections and filtered chronology; 320/390px grids/cards without horizontal overflow; driver selection/on-route/detail; customer steps 1–3 without submission; fixed modal header/footer, exactly one overflowing body, exterior 42px X on desktop/phone, native required-field rejection and successful local-only fixture submission. Fixtures use synthetic props and are removed before commit. No real request, upload, email, payment or production data was created. Live authenticated and physical-camera review remains for the reviewer.

This round passed typecheck, lint (zero warnings), 219 tests (38 CommonJS + 181 TypeScript) and production build. Build used non-secret placeholder public configuration, not production credentials. No migrations or server business actions changed.

## Unified reference / Settings follow-up (November 2026)

- `hextech-unified.css` is the final app presentation layer: supplied dark palette,
  gold bracket corners and hex icons, self-hosted Cinzel headings, unified tabs,
  dark forms, full-width tables, mobile cards, muted action buttons, exterior X.
- Settings: General, Pick & Return, Prices & Taxes, Notifications, Users & Roles.
  Business/workspace/departure settings are grouped; rules move to `/app/reference`.
  Notification delivery monitoring moves to `/app/support/monitoring` and remains
  Owner-only. Support inbox permissions and all mutation/RLS checks are unchanged.
- Calendar/fiscal reporting writes the original four `MM-DD` fields to the existing
  action/RPC. Incompatible custom dates remain the selected, preserved option until
  the Owner explicitly chooses a new preset. No migration or scheduling change.
- Categories keep status plus their own inline Archive/Reactivate action. Closed
  creation disclosures do not leak their actions into the fixed footer.
- Developer setup instructions and provider IDs are hidden in presentation. Stored
  credentials, test recipient, account relationships and settings remain untouched.
  Invite/link-existing remain the same Owner-checked server actions in one UI entry.
- Approved shared fix: `HTMLFormElement.id` is shadowed by a named `id` input. The
  previous ModalActions code generated `form="[object HTMLInputElement]"`, so even
  Approve on a normal page could become detached from its form. Attribute access
  fixes this; inline/non-modal buttons keep native association. A regression test
  covers the shadowed property, and an isolated browser test created a draft quote.
- Support/Questions now have distinct headings and an explicit mailbox partition;
  selected conversations must also match the selected mailbox/status. The original
  code already filtered hello from support, so no duplicated production rows have
  been inferred or relabeled. No changes to ingestion, sending or closure protocol.
- Production read-only diagnosis: old visual TEST requests have `details.items` but
  omit `details.quote_items`; `private.get_tagged_scope` returns “Add at least one
  item” for those records. This is separate from the UI submit bug. No TEST data
  repair, production approval, reset, or seeding has been performed in this round.
  MLab will validate the updated preview separately; data repair/reset needs its
  own reviewed inventory/plan, scoped to ToolTag and preserving BOFT/configuration.

Validation for this follow-up: typecheck, lint, 222 tests (38 CJS + 184 TS),
and production build passed. Isolated browser checks covered draft creation,
mailbox separation, fiscal persistence, inline category actions, zero desktop
table right gap, 320/390px exterior X visibility and fixed header/footer scrolling.
