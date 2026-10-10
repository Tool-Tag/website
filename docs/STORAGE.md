# ToolTag storage architecture

## Current source of truth

Supabase is primary for the complete ToolTag record:

- **Postgres**: customers, quotes, jobs, finance, document metadata, hashes, relations and immutable snapshots.
- **Supabase Storage**: every new binary file, including evidence, uploaded receipts/payment documents, quote images and newly generated accepted PDFs.
- Storage buckets are private. Authenticated unit members may read their unit objects; only ToolTag admins may create/update/delete normal app objects. Public customer access is mediated by ToolTag token-authorized routes rather than raw Storage URLs.
- Metadata is registered first as `pending`; the workflow record becomes `Available` only after the Storage upload is confirmed as `stored`. A failed upload becomes `failed` and does not satisfy evidence gates.

Google Drive is **not** a primary store. The app must not create/update Drive folders or files and must not accept new Drive IDs. A future periodic backup-only synchronization from Supabase to Drive is explicitly outside this step.

## Historical Drive audit — 2026-10-09

Production had 27 document rows before this change:

- 9 rows carried a `drive_file_id` and `legacy_drive` provider.
- All 9 IDs were resolved through the connected Drive metadata API. Every ID currently resolves to a **folder**, not to the JPEG filename recorded in the ToolTag document row. Therefore the old `/file/d/{id}/view` links were not reliable evidence-file links.
- Those IDs are preserved read-only for audit/history. Internal UI uses a generic **Legacy Drive reference** link and never treats it as the primary binary.
- 18 document rows were historical metadata-only rows with the old pending-Drive state. They are not rewritten or falsely marked stored; UI labels them **Historical metadata only**.
- 8 accepted Agreement PDFs already existed as private PostgreSQL artifacts. They remain a read-only compatibility fallback so historical accepted documents are not regenerated or altered. Newly generated accepted PDFs go to Supabase Storage.
- 6 final Job receipts carried the old pending-Drive status. A final receipt is currently a structured immutable Postgres snapshot/print view, not a generated binary. New receipts are therefore `not_applicable` for binary Storage unless a binary is explicitly generated in a later feature.

No historical Drive ID or accepted-document snapshot is deleted by the Storage migration.

## Buckets

- `tooltag-files`: evidence, uploaded receipt/document binaries, accepted PDFs.
- `quote-images`: engraving/quote images and logos.
- `payment-proofs`: existing Zelle/Venmo proof images; already Storage-backed before this change.

The migration creates/locks the first two private buckets and their RLS policies. The existing payment-proof flow is unchanged.

## Future backup

A future job may copy Supabase Storage objects to Google Drive for backup. It must be one-way backup behavior and must never make Drive paths/IDs part of ToolTag business logic. That job is not implemented in this step.
