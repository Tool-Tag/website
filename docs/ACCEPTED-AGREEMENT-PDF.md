# Accepted Quote + Agreement PDF — phase 1

New acceptances retain the existing atomic Job/Sale creation. Migration `202610030006_accepted_agreement_pdf.sql` then freezes one `accepted_documents` record per quote/agreement, with UUID primary key and a unique `TT-AGR-YYYY-#####` folio. Its dedicated counter uses the ToolTag business timezone and does not consume Quote/Job/Sale numbers. Revisions get a new folio linked to the previous accepted document. No existing acceptance is backfilled or edited.

The legal template is never interpolated or modified. The snapshot stores the exact assigned policy title, version and content separately from customer/company, selected recipient, quote scope/prices/fees, Job/Sale IDs, timestamps and both acknowledgments. Canonical representation is PostgreSQL JSONB text (`canonical_snapshot`), stored verbatim and SHA-256 hashed. It must not be reconstructed by JSON.stringify for verification. Immutable triggers prohibit editing or deleting the accepted document or the stored PDF.

## PDF and durable storage

`pdf-lib` composes a paginated letter-size PDF with ToolTag header, scope, exact legal text, electronic acceptance and full snapshot fingerprint. There is no handwritten signature. Newly generated accepted PDFs are stored in the private `tooltag-files` Supabase Storage bucket and linked by bucket/path plus SHA-256 in the accepted-document status and document metadata. Both messages and later downloads use those same stored bytes. PDF generation is asynchronous from business acceptance, and failure cannot undo an accepted Job/Sale. Historical PDFs already present in `private.accepted_pdf_artifacts` remain a read-only compatibility fallback; new PDFs are not written there.

Accepted PDFs are private Supabase Storage objects; direct provider URLs are not exposed to customers. Maximum size is 4 MB. The standard PDF font covers ordinary English/Spanish text; unsupported characters cause explicit generation failure rather than silently altering legal text. Long content wraps and paginates. Google Drive is not a primary store and receives no new writes from this app; a future backup-only synchronization job is out of scope.

## Test-only email behavior

Two independently tracked notifications: customer copy and ToolTag copy. Both go only to `quotes@tooltag.martinlab.studio`, with prefixes `[TEST CUSTOMER COPY]` and `[TEST TOOLTAG COPY]`. The original selected quote recipient stays immutable in the document but is not used as an outbound address in this phase.

No mail is sent by this workflow unless all existing OAuth credentials are configured AND:

- TOOLTAG_MAIL_MODE=test-delivery
- TOOLTAG_MAIL_TEST_RECIPIENT=quotes@tooltag.martinlab.studio
- Local sending remains explicitly disabled unless TOOLTAG_MAIL_ALLOW_LOCAL_SEND=true.

The code does not change any mail-mode variable and refuses to send these copies in `live` mode. From/Reply-To use the existing Quotes department configuration. The former standalone agreement confirmation is suppressed for new PDF-backed acceptances to avoid duplicate confirmations. Other existing notification logic remains intact.

SUPABASE_SERVICE_ROLE_KEY enables automatic processing after acceptance and the scheduled worker. Without it, an authorized administrator can process an individual document from the Quote/Job page using their authenticated session. No service key is exposed to the browser.

## Admin and retries

Quote and Job pages show the folio, policy version, acceptance time, original recipient, PDF status, both email statuses, and Storage status. A private authenticated route `/app/accepted-documents/[id]/pdf` returns the stored PDF; UUID alone does not grant access. Responses are private/no-store.

Processing uses durable database claims. A failed PDF can be retried with its existing folio. A saved PDF is never rendered again. Customer and internal email retries are separate, and Sent copies are not resent. For a stale Queued message or GMAIL_DELIVERY_UNKNOWN, the admin must check Gmail Sent mail and confirm non-delivery before retrying. Gmail accepting a send is not proof of inbox delivery or reading. Retry requests are audited. Interrupted PDF generation or sends must wait ten minutes before a manual retry can release the claim.

## Validation status

Implementation only: no local tests, no local PDF generation, and no test emails were sent by the coding agent, as requested. Production compilation is performed by Vercel during deployment. Functional acceptance, PDF visual inspection and inbox delivery remain unverified until the user exercises the flow. No real customer emails may be used for this phase.

PDF library reference: https://pdf-lib.js.org/docs/api/classes/pdfdocument
