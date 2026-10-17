# Lost customer resolution

## Lifecycle and UI

The workspace Lost menu opens a row list with Jobs-style New / In Process / History tabs. Each row opens a native modal containing the existing customer, job, driver, route, missing pieces and explanation, plus the internal Lost UUID. History is read-only.

New reports capture the aggregate market value of all missing pieces in the failed-return verification form. Existing New reports can enter that value before Notify. Notify freezes it, creates one 90-day hashed capability link, queues an apology email with that value and moves New → In Process. It also uses the existing consent-gated SMS queue; a phone alone is not consent. Retries do not create new notifications or change value/token.

In Process shows Response above each row. Before a choice, clicking shows Waiting for customer response. The public `/lost/[token]` page needs no login and offers Replace Item / Refund money. First response wins; an identical retry succeeds, a different choice requires contacting staff. No internal explanation, staff or driver information is exposed. Staff view refreshes every 20 seconds using the existing refresh component.

An Owner/Manager with Lost management access approves a responded case. Replacement approval creates no financial entry. Submitting secure customer payment details creates one Pending refund obligation for the frozen market value, linked by Lost source ID. It still undergoes standard Refunds review/confirmation, Owner/Manager approval and manual issuance in Finance, proof per method, secure receipt acknowledgment, and five-calendar-day automatic completion. Cash remains prohibited. No provider refund API is invoked.

Approved cases remain In Process. For replacement, staff records what was supplied/delivered in Resolution details and uses Process / Finalize. For refund, issuing the linked Refund automatically moves Lost to History; receipt confirmation continues in Refunds. Finalize records staff, time and details and moves to History; the job stays flagged Lost for historical traceability. History no longer contributes urgent Lost counters.

## Accounting exception

Lost item compensation may exceed service payments. Only a refund created by the guarded Lost payment-submission path has source_kind Lost and a matching approved Lost snapshot. During issuance, this creates an EXPENSE and expense detail in Lost Item Compensation, rather than reversing collections. Ordinary refunds retain their paid-collection cap; Lost obligations do not reserve that service-refund balance. Full approved amount, electronic/Check method, funding account, reference, matching stored screenshot and normal processing windows remain mandatory. Repeated approval/issuance is idempotent.

## Migration / release

New migration: `20261017093434_lost_resolution_market_value.sql`.

It adds columns and a private RLS-protected token table, adds guarded RPCs, extends existing list and SMS paths, and changes the existing refund function definitions through a forward-only migration. No applied migration or baseline is edited. No automatic notification, case conversion, financial issuance or historical replay happens when applying it. Existing records start in New; no value is invented.

The migration has NOT been applied to production. Apply only after separate authorization. Feature branch code requires it for mutations/public links. Missing mail/SMS credentials or non-production mode preserve existing graceful degradation; a queued notification is not a promise of actual receipt. No customer messages or production records were used by tests.

## Validation

Tests exercise migration application against the six baselines and all later migrations in an isolated PGlite database, capability privacy/expiry, first-response immutability, notification/SMS deduplication and consent skipping, replacement completion, Pending refund creation, $500 compensation above service payments, preserved ordinary caps, EXPENSE ledger, idempotent issuance, receipt-confirmation gate and History urgency removal. Unit coverage checks finalization eligibility and the SMS secure path/template. Typecheck/lint/build results are reported with the branch delivery.


## Approval notice and replacement processing (Block 4 continuation)

Additional forward-only migration: `20261017094257_lost_replacement_processing.sql`, NOT applied remotely. Apply only after the preceding Lost migration and separate authorization.

Approval queues one customer email and consent-gated SMS saying work has started on their chosen resolution, with a 5–7-business-day processing window. Approval retries do not send duplicates.

An approved replacement shows Process. Clicking opens a confirmation dialog: make sure the replacement is physically at the shop. Not yet closes that dialog without confirming or opening Finance. Confirmed records staff/time on the server and opens the existing Finance MovementForm inside an expense modal, locked to Expense. It preserves Finance's existing Owner-only expense permissions, required amount/account/category/vendor, closed-period rules, paid-by handling, and idempotent record_movement path. The actual purchase cost can differ from the customer's frozen market value.

The new guarded RPC atomically records the Finance expense and stores its transaction ID on the Lost case. Retries cannot create a second expense, and changed retry data fails. The Lost modal displays the transaction ID and changes Process to Finalize. The server refuses replacement finalization without the shop confirmation and a linked Active expense. Resolution notes are still required. Refund processing remains in Refunds; issuance automatically archives the Lost resolution while preserving its receipt-confirmation lifecycle.


## Customer fulfillment and private refund instructions

Forward-only migration `20261017100957_lost_customer_fulfillment.sql` follows the three Lost migrations above (including `20261017095441_driver_loss_agreements.sql`). None has been applied to production by this work.

Replacement Finalize means ready at the shop, not a claim that physical handover already happened. It queues one ready email and consent-gated SMS, renews the existing secure link for 90 days, and archives the resolution. The customer selects Shop pickup or Free delivery. Free delivery requires a full address, prefilled from the existing customer/job details where available. No date selector is shown. The immutable first choice can only be changed through staff coordination.

Free delivery creates a separate `lost_replacement_deliveries` request linked to the Lost case and original Job, with `top_priority=true`, `delivery_fee=0`, and exactly the missing-item manifest. It appears first in To Schedule with a priority/free badge. The existing scheduled worker assigns the next configured future Delivery block with space (at least one hour before departure); staff can invoke the same assignment immediately from the queue. The normal route capacity and driver-eligibility guards remain. Priority is preserved during automatic/manual ordering. No new Quote, Job, Sale or service charge is created; the original Job remains Lost.

Routes and the driver view include the replacement request despite the original Job's Lost flag. Load/returned-item verification uses only the replacement manifest. The free stop never inherits the original service balance or cash-payment controls. Attended handover and stored Delivery Evidence are required. A missed replacement stays Failed for staff coordination; this feature does not invent a further fee or automatic paid retry. Existing route closure still requires returned-piece verification. Replacement evidence remains on the existing Job and stop, without duplication.

For Refund money, the secure customer page collects account holder and the original electronic method; original Cash permits Zelle, Venmo, bank transfer or Check. Zelle needs email/phone, Venmo a handle, transfer a valid routing/account number, Check a postal address. Card refunds go to the original card only: no card number, expiry or CVV is collected. The guarded server submission creates one Pending market-value Refund with the Lost UUID as source. Lost approval is still required before standard Refunds confirmation/issuance; repeated submissions do not create another obligation.

### Required server-only configuration

Set `TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY` in Vercel to a randomly generated 32-byte key encoded as base64. Keep it in the secret manager/local ignored environment only; never commit the value or expose it as NEXT_PUBLIC. Generate with `openssl rand -base64 32`. Preserve/back up this key securely: replacing it makes existing instructions unreadable unless a separate controlled re-encryption is performed.

Payment instructions use AES-256-GCM with the Lost UUID as authenticated context, stored in an RLS-protected private table. Only the server submission may write them; the authenticated refund-permission RPC returns ciphertext for server-side decryption. Only authorized refund staff see instructions in the Refund modal/Finance execution view. They are excluded from emails, SMS, public links, audit payloads and accounting snapshots. Missing configuration prevents submission with an explicit customer error and flags unreadable staff instructions. No real payment or bank transfer is automated.

### Operational limits

Production requires separately approved migrations and the new encryption key. Automatic scheduling also requires the existing route worker to be active. Delivery estimates are approximate and the existing configured route weekdays/windows remain unchanged. No production emails, SMS, payouts or database writes were used for isolated validation.
