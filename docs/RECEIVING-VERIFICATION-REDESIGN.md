# Receiving / Verification redesign

Branch: feature/header-style-preview. No production schema or records changed.

## Diagnosis

Read-only inspection of production `public.verify_shop_item(uuid)` confirmed it checks for a document with the same job_id, type Receiving Evidence and status Available. Its error “Review receiving photos before verifying items” means that document is absent; it does not track whether the user viewed a photo.

The existing seed TEST-J-20261011-04 has two unverified pieces, pickup status Picked Up, and no evidence documents. This explains the guard failure for that test job. Other picked-up jobs inspected have Receiving Evidence; one has legacy metadata without a stored binary, which is a distinct condition. No historical evidence was fabricated or changed.

## Fix

Pick Up Receiving / Verification is a list opening native modal dialogs with customer/job information, existing evidence gallery and a piece checklist. Each modal now includes the existing receiving-photo uploader (Take photo / Choose file), with the existing storage/metadata registration, permissions and limits. Without an Available Receiving Evidence record, the checklist explains the missing prerequisite and disables verification. Successful upload refreshes the current route and enables the checklist. The backend guard remains authoritative, including stale UI and direct calls; the server action translates its ambiguous error into upload/retry instructions.

All pieces must be checked before saving. Each is persisted through the existing authorized verify_shop_item RPC. If a later piece fails, earlier successful checks stay recorded; retry skips them. The Job detail's existing verification controls remain supported. No new Lost behavior or exemption from photo requirements was added.

Main Pick Up / Delivery tabs use the reusable Jobs-style gold indicator; five folder tabs share the content panel edge. Delivery verification keeps its existing returned-items/loss workflow.
