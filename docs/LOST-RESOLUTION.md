# Lost customer resolution

## Lifecycle and UI

The workspace Lost menu opens a row list with Jobs-style New / In Process / History tabs. Each row opens a native modal containing the existing customer, job, driver, route, missing pieces and explanation, plus the internal Lost UUID. History is read-only.

New reports capture the aggregate market value of all missing pieces in the failed-return verification form. Existing New reports can enter that value before Notify. Notify freezes it, creates one 90-day hashed capability link, queues an apology email with that value and moves New → In Process. It also uses the existing consent-gated SMS queue; a phone alone is not consent. Retries do not create new notifications or change value/token.

In Process shows Response above each row. Before a choice, clicking shows Waiting for customer response. The public `/lost/[token]` page needs no login and offers Replace Item / Refund money. First response wins; an identical retry succeeds, a different choice requires contacting staff. No internal explanation, staff or driver information is exposed. Staff view refreshes every 20 seconds using the existing refresh component.

An Owner/Manager with Lost management access approves a responded case. Replacement approval creates no financial entry. Refund approval creates one Pending refund obligation for the frozen market value, linked by Lost source ID. It still undergoes standard Refunds review/confirmation, Owner/Manager approval and manual issuance in Finance, proof per method, secure receipt acknowledgment, and five-calendar-day automatic completion. Cash remains prohibited. No provider refund API is invoked.

Approved cases remain In Process. For replacement, staff records what was supplied/delivered in Resolution details and uses Process / Finalize. For refund, the same action is blocked until the linked Refund is Completed. Finalize records staff, time and details and moves to History; the job stays flagged Lost for historical traceability. History no longer contributes urgent Lost counters.

## Accounting exception

Lost item compensation may exceed service payments. Only a refund created by the guarded Lost approval path has source_kind Lost and a matching approved Lost snapshot. During issuance, this creates an EXPENSE and expense detail in Lost Item Compensation, rather than reversing collections. Ordinary refunds retain their paid-collection cap; Lost obligations do not reserve that service-refund balance. Full approved amount, electronic/Check method, funding account, reference, matching stored screenshot and normal processing windows remain mandatory. Repeated approval/issuance is idempotent.

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

The new guarded RPC atomically records the Finance expense and stores its transaction ID on the Lost case. Retries cannot create a second expense, and changed retry data fails. The Lost modal displays the transaction ID and changes Process to Finalize. The server refuses replacement finalization without the shop confirmation and a linked Active expense. Resolution notes are still required. Refund processing remains in Refunds; its Finalize appears only after Completed.
