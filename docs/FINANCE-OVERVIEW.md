# Finance — Block 5

## Overview definitions

- **Expenses** sums every negative cash effect attributed to ToolTag, across every TT account. This includes business expenses/equipment purchases, customer refunds, owner withdrawals/reimbursements and transfers out. Owner-funded purchases become outgoing TT funds when reimbursed. Voided transactions are excluded. Incoming refunds do not reduce this gross-outflow total.
- **Net Profit** is the requested Overview metric: registered sales revenue (excluding sales tax), minus the Expenses total above. It is not based on collections. Refunds are deducted once as outgoing funds, not again as negative revenue. Owner contributions are not revenue. Positive border/value are green, negative red, zero neutral.
- Existing ledger, finance_summary, monthly close formulas and other metrics are retained; the new Overview metric follows the expressly requested all-outflow definition.
- **Sales Tax** shows accumulated recorded sales tax less the tax component of customer refunds, and the same measure for the current configured quarter. It derives from the ledger's existing pinned tax-exclusive revenue and transaction totals, not today's tax rate. Legacy untaxed sales remain untaxed; vendor refunds do not become customer tax reversals. This is a reporting total, not tax payments/remittance tracking.

Quarter dates are configured by Owner under Settings → Prices → Sales Tax Reporting Quarters. Four annual start dates define consecutive, nonoverlapping periods. Defaults: January 1 / April 1 / July 1 / October 1. Fiscal-year wrap is supported; invalid dates, duplicate/unordered boundaries and February 29 are rejected. Dates use America/Denver. The accumulated history is never reset. A tab left open checks for quarter rollover every 30 seconds and on visibility changes, refreshing only when the reporting boundary changes.

Finance-only readers obtain just the quarter dates through a narrow permission-guarded RPC; they do not need access to the entire settings row. Changing reporting dates does not edit transactions, accepted quotes, tax rates or Agreement text.

## Lists and navigation

Transactions includes GET search across description/vendor/reference, filters for type/status/account/from/to, an exact filtered count and server pagination of at most 20 records. Filters persist in Previous/Next URLs; applying or clearing filters resets pagination. Queries are tenant-scoped, stable by date/created/id, and do not use the generic 200-row list helper.

Transactions, Sales, Expenses, Finance Refunds and SMS Costs share a sticky header/navigation frame. Transactions keeps its search/filter controls in the same stack; narrow screens can scroll the filter bar horizontally. Equipment is removed from Finance's tab navigation; the existing Equipment module/data remains.

## Expense → equipment registration

Saving a manual Equipment-category expense returns to Expenses and automatically opens Register Equipment for an Owner. The saved expense is loaded by its exact transaction ID, independent of the list limit. The existing AssetForm locks Purchased/source expense to that transaction and prefills its description. Existing create_asset validation and the unique source-expense constraint prevent duplicates.

The equipment's source_expense_id and the expense's linked_asset_id retain both directions. Creating equipment does not create another expense. Closing the modal preserves the purchase; a reopen button remains. Successful registration returns to Expenses without the auto-open query parameter.

## Required expense receipt

New manual TT EXPENSE registrations of $75.00 or more require an image uploaded before recording. Take photo / Choose file supports JPEG, PNG or WebP up to 3.5 MB. Client validation prevents oversized submissions; the server also checks size/MIME/image signature. The upload is private/internal and initially staged as an unlinked Other document. No financial expense exists yet.

The guarded public.record_movement validates the staged file's unit, uploader, type, status, Storage object and image metadata, then records the expense and binds its Receipt/transaction_id atomically. Failed uploads, missing/foreign/previously linked documents are rejected. Idempotent request retries still return the same transaction; the legacy entry point cannot be invoked by authenticated clients. The existing receipt-status view now recognizes Supabase files, retaining legacy Drive references for old records.

Receipts below $75 are optional for registration. Historical records, BOFT and existing internal automated ledger postings are not rewritten or backfilled. Lost replacement purchases use the same manual recorder and require the receipt too. Abandoned staged documents remain private and are not ledger expenses.

## Deployment gates

New forward-only migrations, in order:

1. `20261017103110_finance_tax_quarter_settings.sql`
2. `20261017104032_required_expense_receipt.sql`

Neither is applied to production by this batch. Apply only with separate authorization and the preceding branch migrations already present. No existing migration/baseline or Customer Agreement was edited. No additional secret or storage bucket is required.

## Block 5 list-filter completion

Sales, Expenses, Finance Refunds and SMS Costs now use the same GET search/filter and server-side twenty-record pagination pattern as Transactions, inside the existing sticky header/control frame. Applying filters resets to page one; Previous/Next retain them. The full filtered result is counted before paging, with stable date/ID ordering and stale page numbers clamped to the last available page. These lists no longer use the generic 200-row helper.

- Sales: sale number search; payment/refund status; transaction-date range.
- Expenses: description/vendor search; Paid by, Equipment/Operating, receipt status; transaction-date range. The newly saved Equipment expense is still loaded separately by exact transaction ID to open registration even when off-page or filtered out.
- Finance Refunds: customer/Job/reason/notes/reference search; method/reason; request-date range. Only Approved requests are included. The existing RefundsPanel receives just the selected twenty IDs and retains all issuance/proof/permission behavior. Dedicated Refunds case management and its lifecycle tabs are unchanged.
- SMS Costs: quote/Job/posting-error search; Accumulating/Closed/Needs attention/Unconfirmed acceptance; updated-date range. The embedded Job/Quote SMS table is preserved.

Timestamp ranges use inclusive Denver dates and an exclusive next-day boundary, including 23/25-hour DST days. No new migration or production write is needed for list filters.

## Equipment list and dialogs (Block 6)

Equipment opens as a list with Equipment Name, Category, Serial Number, Warranty Expiration and Cost. Donated equipment explicitly labels its informational estimated value. Clicking a row (or using Enter/Space) opens a read-only detail dialog with the source, dates, status, notes and original Finance expense link.

Register Equipment opens the existing registration form in a dialog, using the same permission gate and server action. A successful save closes the dialog and refreshes the list. Linked-purchase deep links remain supported. The existing automatic registration dialog after an Equipment expense is unchanged. No database migration is required.
