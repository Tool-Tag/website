# Mobile navigation and upload cleanup

## Navigation

At 850px and below the workspace uses a sticky icon bar, grouped slide-in navigation, search dialog, user dropdown (name and Sign Out only) and Dashboard/Quotes/Jobs/Finance bottom links. Existing permission checks govern every destination; no role receives additional access. All existing sidebar and header destinations are preserved. Sections are Main, Operations, Business and System to keep UI text English. Drawer clicks/Escape close the native dialog; opening it locks background scrolling; switching to desktop closes mobile dialogs. Desktop sidebar, utility buttons, search and user controls remain as before.

Shared mobile rules keep grids, forms, tabs, tables and page headers within their available width. The Recent Activity table wraps human-readable descriptions and dates rather than exposing audit column names. Pending Quotes now says “accepted”. Mobile search uses a short placeholder and a full descriptive label.

## Uploads

Confirmed clarification: keep uploads with one standard file input. Removed paired Take photo / Choose file controls from EvidenceUpload, QuoteImageInput and ToolPhotoInput, which cover job/driver evidence, expenses, Lost receipts, quote artwork and Get Tagged. Payment/refund proofs already use a single file input. No camera capture attributes remain. HEIC conversion, previews/removal, optional intake photos, required receipt/payment proof gates and server/database enforcement remain intact.

## Modal audit

All React dialog/role=dialog source components use ModalClose or DialogClose (which delegates to ModalClose). Shared placement now chooses a genuinely exterior right gutter, or the space above a wide panel, instead of clamping inside the panel. Mobile panel widths/heights reserve exterior room. Visual viewport changes and scrolling update placement. Static homepage/Falcon/Times dismissal helpers follow the same exterior fallback. Image-removal X controls remain on their image previews; they are not dialog dismissal controls.

## Verification

- Local browser fixture at 390px: compact top bar, content-first layout, grouped drawer with all destinations, readable activity and standard receipt input.
- 320px: no page-wide horizontal overflow; search input fits; X right edge312 inside viewport320 while outside panel.
- 390px drawer: panel right302, X left308 (outside).
- Desktop1280px: mobile header hidden, desktop header/sidebar visible, mobile dialogs closed.
- Unit tests cover readable audit descriptions and exterior modal geometry; full existing tests cover receipt gates/HEIC and permissions.
- Full source sweep: no custom Take photo / Choose file buttons or file-input capture attributes remain.
- Temporary UI fixture removed. No production data, emails, migrations or business-rule changes.

Screenshots: /private/tmp/tooltag-mobile-dashboard.png and /private/tmp/tooltag-mobile-drawer.png. Browser fixture checks are representative shared-layout tests, not a claim that every authenticated production page was manually exercised on a physical phone.
