# Photo-proof corrections

Branch: feature/photo-proof-fixes. No production migration applied by this change.

- Expense receipts: fix Owner fallback in canAny, show the receipt uploader only for Expense amounts >= $75, and show the missing-proof banner only after an attempted save. Both the server-action and database $75 gates remain unchanged. Expense recording is currently Owner-only; this change does not grant Employees expense access.
- Lost replacement expenses: persist `lost_jobs.missing_receipt` when the replacement expense is linked. Missing proof below $75 does not block recording; show Missing Receipt on the Lost list, case, and expense record. No follow-up workflow is introduced.
- Lodging: remove the selector and lodging-only requirement in the expense receipt-status view. Preserve historical lodging data.
- Transaction receipt and Job Issue/Review evidence: add camera and file choices. Camera selection is opened synchronously from the user's click with capture=environment and an image accept filter.
- Get Tagged: optional photo per tool/item; camera/file options, local preview and remove. Uploads use the existing private tooltag-files bucket, nonce-bound requests and server-only metadata, byte/type/size validation, and per-session/network limits. Request submission validates selected photo ownership. Staff can open the photo from intake Quote review through an authenticated route. No image is required to submit.
- Refund screenshot control stays file-only.
- Modal X controls: use a shared fixed-position X outside the visible panel, preserving native top-layer/focus scope and original dismissal handlers. Include role-based dialogs, public homepage dialogs, Falcon and Times. Close controls retain X labels; image-removal X controls are not moved.

## Additive migration

`20261018200904_photo_proof_receipts_and_intake.sql` adds the Lost mark and trigger, extends its list RPC and receipt status view, removes the lodging exception, and creates private intake-photo metadata with a service-role-only reservation RPC. Apply only after production approval.

## Validation

- Local isolated Owner UI: uploader hidden before $75, rendered at $75 with both choices, no reactive error, save attempt without proof blocked and shows banner.
- Local long-modal UI: X outside panel, remains visible after scrolling, closes correctly.
- Automated tests cover Owner/Employee boundaries, optional photo IDs, Lost receipt thresholds/mark/status, stored-proof registration, intake metadata privileges/limits, and existing refund proofs/receiving/delivery logic.
- Typecheck, lint and production build use local-only configuration; no real payments, mail or customer submissions used.
