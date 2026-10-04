# ToolTag commercial workflow — code-only delivery

This change implements the requested workflow in the existing project. Per the latest instruction, no local tests, typecheck, lint, build, deployment, production migration, environment changes, or email sends were performed for this change.

## Installation requirements (not executed)

The remote read attempted at the start showed that `public.accepted_documents` did not yet exist. The already checked-in migration `202610030006_accepted_agreement_pdf.sql` is therefore a prerequisite. New migrations, in order:

- 202610030007_engraving_pricing.sql
- 202610030008_job_extensions_delivery.sql
- 202610030009_production_mail_boundary.sql

Do not publish the application ahead of these schema changes. Apply migrations through the existing release process, then publish the application. No accepted quote, acceptance, old PDF, or BOFT financial record is rewritten by these migrations.

## Pricing

Each physical item includes its first engraving. Every additional engraving adds $5 per piece: quantity × max(mark count − 1, 0) × $5. Painting is a separate $2 per painted piece. Logo adaptation remains a separate $3 per unique design in that quote/extension. Lines with different configurations must be entered separately.

`private.priced_scope` is the shared database pricing function for quotes, revisions and extensions. Base item snapshots preserve count, base price, additional engraving amount, paint amount and resulting line total; explicit fee lines make quote totals auditable. Historical lines have no new pricing version and are not recalculated. The UI uses the same rules for estimates before saving; the database computes authoritative prices.

## Production mail and backlog safety

The environment change, when deliberately releasing, is `TOOLTAG_MAIL_MODE=live`. It was NOT made in this task. Existing OAuth variables are reused.

In Settings, the admin must also activate the cutoff for **new** mail. This deliberate database activation is an additional backlog safeguard, not another Vercel variable. Existing notifications are classified `legacy`, remain unchanged, and cannot be automatically claimed by live workers. New notifications are eligible only for a post-activation source event or an explicitly identified new administrative action. Historical auto-close events do not become eligible merely because the worker runs after activation.

Individual failures/unknown outcomes require deliberate admin retry and Gmail Sent reconciliation. Historical accepted documents need explicit “Authorize real copies” before production delivery; old test notification history is kept. Gmail accepting a message is not proof of inbox delivery or reading. No production mail configuration was changed by the coding agent.

## Quotes and official PDFs

Only usable personal/company email choices are shown. When both exist, selection is required. The selected recipient is fixed on that quote version; changing it requires a revision.

The existing PDF generator/artifact store is reused. One immutable PDF is attached to both copies and served by the authenticated download route. Live customer copies go to the frozen quote recipient; internal copies go to quotes@. Test copies stay test-only. No template placeholders or rewritten legal terms are introduced.

Older accepted records with a complete frozen snapshot can prepare a missing document through an admin action without another acceptance/Job/Sale. An existing document/folio is reused. Missing historical company information is left absent rather than reconstructed from today's Customer record. The intended repair of TT-J-2026-00006 is coded but was not executed; its document state could not be inspected because the PDF tables are not yet installed.

## Job extensions and accounting

/work/[token] is the pre-delivery review: approved work, completed-evidence panel, Ready for Delivery, or a request for additional work. This is separate from /completion/[token], which confirms physical receipt.

Each extension has UUID, job-local sequence and code TT-J-YYYY-#####/Xn. Repeated responses on the same review cannot create another extension. The admin prices the proposal using the same item builder. /extension/[token] records separate approval, immutable scope, price and acceptance hash. Original quote/agreement remain unchanged. Unapproved/cancelled proposals contribute nothing to totals and unresolved proposals block delivery. Approval resumes In Process; returning to Ready requires completed evidence newer than the latest extension approval.

Each approved extension creates exactly one additional SALE ledger component, linked to the same parent Job through the extension. It does not update the historical base SALE, which avoids rewriting closed-period revenue. No extra “grand total” SALE is inserted. Job totals sum base plus approved components once. Collections are recorded against the relevant base or extension sale; a payment covering multiple components must currently be allocated as separate collections. Links to these sale components are shown on the Job. Refunds retain existing finance semantics and are shown independently.

## Delivery and payment summary

A successful physical-delivery acknowledgment stores one immutable record and scope hash, confirms receipt only, and never asserts payment or waives rights. Administrative deemed acceptance remains distinct and never creates an explicit customer acknowledgment.

The final job receipt freezes the base scope, approved extensions, payment history, grand total, amount collected, refunds and balance. It reports PAID IN FULL only when the current balance is zero and there are no refund adjustments. Its date uses the last qualifying collection date. Same snapshot means same logical receipt. It is generated/queued at delivery, after a new collection on a delivered job, or manually from the Job; Billing sends the summary in the email body. The admin can view/print it. Agreement PDFs remain the separate official acceptance documents. Receipts are metadata/snapshots pending Drive storage; no Drive upload is claimed.

## Drive: visual preparation only

Drive is intentionally NOT connected in this phase. No API scopes or credentials are requested/used. Receiving and Completed sections show gallery cards and in-app placeholder viewers. Upload Photo/File controls are disabled. There are no real thumbnails or file streams until the next Drive phase. The legacy admin-only manual file-ID link remains secondary so the existing evidence-gated workflow can still operate. No normal customer is redirected to Drive.

Future folders: ToolTag Customers / CUST... / Customer Documents; Jobs / TT-J... / Quote, Agreement, Receiving, Completed, Payments, Issue-Review, Other. Existing Drive IDs and metadata are preserved. Later authorization should use a deliberately configured Drive OAuth grant and least-privilege access to ToolTag-managed files, independent of Gmail-only tokens.

## Navigation and release limitations

Internal pages have application-aware parent navigation. Job pages show commercial components, payment links, customer review status, evidence sections, acceptance PDF and delivery status.

No tests or compilation were run, per instruction. Code has only been reviewed by reading it. End-to-end behavior, visual rendering and email receipt are unverified. Do not interpret this code-only delivery as a tested or deployed release. Drive remains intentionally disabled.

### Prepared routes

- /app/job-extensions/[id]: price/edit draft, send proposal, cancel unaccepted proposal
- /extension/[token]: customer extension approval
- /work/[token]: completed-work review before delivery
- /completion/[token]: physical delivery acknowledgment
- /app/job-receipts/[id]: immutable consolidated payment summary
- Existing Quote/Job pages: accepted-PDF repair/retry and lifecycle panels

No Git commit or push is included in this code-only task. Review changes in GitHub Desktop before the separately authorized release.
