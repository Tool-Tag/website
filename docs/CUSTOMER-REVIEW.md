# Quote + Agreement workflow — 2026-10-03

Implemented and validated locally, then published on 2026-10-03 after explicit user authorization. Migration 202610030002 was applied and Vercel deployment dpl_51j6kP4yuBVxvsMwFYrkWgD6TN5G was promoted to tooltag.martinlab.studio. No DNS changes, BOFT data changes, real emails or Drive uploads were performed.

## Customer experience

- Articles are added/edited in a modal. Each mark is one engraving per article, with its own location and text or logo description/link.
- Paint fill opens a separate modal: single color or multiple-color instructions. An article summary must be confirmed before it joins the quote.
- Enviar cotización validates the customer email, items, positive total and a published Agreement. It creates the review link and Sent timestamp once. Email remains explicitly Pending Integration.
- Repeated send reuses the retained link and first-send expiration. Explicit regeneration invalidates all older links. Legacy links created before this migration remain usable; their original plaintext tokens cannot be recovered, so the first new send creates a retained link without revoking those old links.
- `/review/[token]` shows the full scope and assigned Agreement version together. `/accept/[token]` uses the same page for existing URLs.
- Two acknowledgments and one Accept Quote & Agreement action commit the acceptance, job and sale together. Invalid, expired or superseded commercial acceptances cannot bypass the checks. Replays do not duplicate work or sales.
- The accepted page is a printable HTML record. Accepted records remain readable via their secure link after the quote's acceptance deadline; unaccepted expired quotes cannot be accepted.

## Stored records

New migration: `supabase/migrations/202610030002_customer_review.sql` (requires all existing migrations, including `202610030001_quote_marks.sql`).

Additive columns: quote_items.paint_details, quotes.review_snapshot, agreements.commercial_snapshot, agreements.snapshot_hash and agreements.acceptance_type. Private quote_delivery stores the reusable bearer token, inaccessible to browser roles. Existing IDs and rows are preserved.

Sent commercial scope and published policies are frozen. Acceptance includes customer/contact, quote ID/version, policy ID/version/content, scope, total, server timestamp and SHA-256 verification. Existing accepted rows are not backfilled or altered: their old signer and sale version are used when displaying historical records. A commercial revision adds a new acceptance/sale version while retaining the original Job/Sale identity.

Quote, reminder, confirmation and pending Drive archive events persist in notifications. Mail events contain the frozen template data, not a delivery claim. The combined flow no longer queues the old intermediate Agreement acceptance email request.

## Email and documents

`src/lib/integrations/quote-mail.ts` provides escaped HTML/plain-text quote and confirmation templates plus a transport interface. Test/preview mode never calls the transport. No Google Workspace transport is connected yet; setting mode=live alone does not send anything.

Admin-only preview: `/app/quotes/[id]/email`. It shows the quote email before acceptance and the confirmation afterward. Customer copies use the immutable printable review page; no PDF dependency or Supabase Storage was added.

Configuration:

- TOOLTAG_PUBLIC_URL: production site origin.
- TOOLTAG_MAIL_FROM: approved sender, configured after Workspace is ready.
- TOOLTAG_MAIL_MODE: preview until the Google Workspace transport is implemented and authenticated.

Still pending: Google Workspace DNS/authentication credentials and transport connection; real quote/confirmation/reminder delivery; Drive authentication and folder/file synchronization. Drive archive events already retain quote/job/agreement IDs and snapshot hash. No new paid provider was selected. SMS remains out of scope.

Reminders are due two calendar days before expiry, with the seven-calendar-day window calculated in the unit timezone. The worker marks due reminder events while leaving delivery pending. Production scheduling still needs the existing CRON_SECRET and SUPABASE_SERVICE_ROLE_KEY configuration; this task did not change production environment settings.

## Validation

Passed: typecheck, lint, production build, 25 existing Hub tests, four core tests, 14 existing database tests, and these six additional database/mail tests (49 total):

1. A–I: valid send requires Agreement; stable private link, calendar expiry, pinned policy and email snapshot.
2. J–P: both acknowledgments, atomic idempotent job/sale, contact snapshot, immutable records and audit.
3. Q–S: bad/expired links rejected, rotation invalidates old link, revisions preserve history and reuse job/sale.
4. Reminder becomes due two calendar days before expiry; no false delivery; worker idempotent.
5. T: mail previews escape HTML and never send in test mode or without transport.
6. Additive upgrade preserves an already accepted legacy quote and its original contact/sale.

Browser exercise used the isolated in-memory PostgreSQL fixture, not hosted Supabase: Test Customer; DeWalt Battery with MARTIN on left and right, white paint; DeWalt Charger with a logo on top; $30+$20+$3 adaptation=$53. Confirmed edit/summary, Send, email preview, anonymous customer review, missing acknowledgment blocking submission, acceptance, reload, and confirmation preview. Desktop and 390px mobile inspected.

Post-browser database inspection confirmed exactly one Accepted quote, one Authorized job, one sale, one acceptance with snapshot/hash and contact data, and persisted notifications/audit. All share sequence 2026-00001; accepted amount is $53. Existing database tests also cover receiving/completed evidence gates and delivery progression. Test records were never inserted into production.

## Release

Ready for a coordinated database + application release, not a code-only push. The migration revokes the old separate acceptance RPCs in favor of accept_review; the old production UI must not be left running against that migration for an extended period. Prepare the new build, apply the versioned migration and switch to the new deployment in the same release window. Already-open old acceptance forms should be refreshed. No destructive reset or data rewrite is required.

After release, verify an approved Agreement is published in Settings and use Copy Link while email remains unconfigured. Do not publish the test fixture's placeholder policy. Verify scheduler credentials separately. The Home and Hub files in dist are unchanged.

Production verification: Home and login return 200; private /app redirects unauthenticated visitors to login; both review and legacy accept routes reject invalid tokens and return no-referrer headers. Database confirms the migration and combined acceptance function exist. Source changes still await the user’s GitHub Desktop commit/push; the live release was made directly through Vercel CLI.
