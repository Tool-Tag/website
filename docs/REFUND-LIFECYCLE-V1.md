# Refund lifecycle V1

## Operator workflow

Finance → Refunds and the Job refund panel have two tabs:

- **Active:** Pending, In Review, Approved, Issued.
- **History:** Completed and Rejected, read-only.

Pending means a new obligation arrived, including existing route/cancellation/missed-pickup sources. Staff with `payments.refund` starts review and confirms eligibility. Approval requires an active **Owner** or an assigned custom **Manager** role, as well as refund access. A normal refund specialist cannot approve their own request merely by having the refund permission. No new Manager role or permissions are automatically assigned.

An Approved refund is ready for manual disbursement when the existing processing-date gate permits. The existing 14-calendar-day reporting and 5–7-business-day processing rules remain unchanged. Owner/Manager approval does not bypass the existing payment cap, reservations, date gate or review of ambiguous provider activity.

## Manual issuance — no provider transfer

V1 never transfers money through Stripe, Zelle, Venmo, banks or checks. Staff executes the payment outside ToolTag, uploads its screenshot, and records the funding account, method and payment reference. Cash refunds remain prohibited. Each screenshot is tagged with its actual refund method; issuance requires a stored PNG/JPEG/WebP screenshot attached to the same refund/Job/unit and matching the selected method.

Recording issuance creates the existing financial refund transactions once, sets Issued, records issuer/time/proof and queues the existing `REFUND_UPDATE` Billing notification. Legacy source records may show that money was processed, but the refund request remains Issued until acknowledgment/timeout. Repeating the issuance action does not create another transfer, ledger entry, notification or public token.

## Customer receipt and completion

The issue notification contains a secure private `/refund/[token]` link. Its page shows the amount, method, reference, issuance time, proof and exact acknowledgment deadline. Screenshot bytes are proxied by `/refund/[token]/proof`; no signed Storage URL or service key reaches the browser. Only hashes of the high-entropy refund tokens are stored; token access is scoped to one refund and expires after 90 days.

The customer can select **Confirm Receipt**. Otherwise the existing scheduled worker moves Issued → Completed after **five calendar days from issuance**, as confirmed by the user. Timeout is explicitly recorded as no response, not as customer acknowledgment. The worker updates only lifecycle/audit data: it does not create another payment or notification. Customer acknowledgment and scheduled completion serialize on the refund row and are idempotent. Existing `run_scheduled_tasks` invokes reconciliation, so no new scheduler/secrets are required.

Historical Completed/Cancelled records are not reprocessed, re-notified or converted. Previously cancelled records remain stored for audit and are excluded from the two requested tabs. The Customer Agreement text and accepted documents are untouched. Active refund badge/urgency calculations include all four active stages, including Issued awaiting acknowledgment.

## Deployment / validation

Additive migration: `20261015024134_refund_approval_issuance_acknowledgment.sql`. Applied migrations/baselines are unchanged. Apply only after review/authorization; this task does not apply production SQL.

Local isolated integration tests cover role restrictions, correct source reservations, screenshot ownership/method, unchanged processing gates, exactly-once ledger/notification behavior, bearer-token access, public acknowledgment, and five-day timeout without extra transactions/notifications. No real customer email or real provider refund is sent during tests.

### Active case review
Active refunds appear as clickable rows. Opening a Pending case in the details modal starts In Review for staff with `payments.refund`; viewers retain read-only access. Reopening never resets the review timestamp or moves later states backward. Approval and manual issuance remain separate explicit actions. The modal preserves its open state while refreshed server details show the review actions.

## Full flow extension

History now contains **Completed and Rejected only**, without edit controls. Staff may reject an In Review case with a required reason; it records actor/time, releases the unpaid reservation and cannot be reopened by later source reconciliation. Completed source records are also frozen. Legacy Cancelled records stay stored and are not rewritten or replayed.

Active rows sort red → orange → green, then longest wait and oldest request. The clock uses **business days from eligibility confirmation**, Denver calendar dates: 1–2 green, 3–4 orange, 5+ red (including overdue cases). An unconfirmed case has no running processing clock and displays zero days / awaiting confirmation. The workspace badge uses the same confirmation origin.

The modal header shows customer, Job, amount, status, wait and urgency dot. Its sections contain origin event/date, the 14-calendar-day reporting check, original/refund methods, requested/issued/unissued amounts, screenshots, contextual actions and notes. New screenshots/notes are blocked for History; final records retain their audit details.

Issued email provides **Confirm Receipt** and a private screenshot link. A refund staff member can also record a customer's Phone/Email confirmation with required notes. This transitions only Issued to Completed, records staff identity/channel and never creates additional ledger entries, provider calls or email. After the five-calendar-day deadline, completion is recorded as **Auto-completed, no response** rather than claiming a customer acknowledgment. History distinguishes **Client confirmed** (including staff-recorded channel) from automatic completion. Existing completion/worker locks and idempotency remain intact.

Additional migration: `20261015032625_refund_rejection_staff_completion.sql`. Apply after `20261015024134_refund_approval_issuance_acknowledgment.sql`, only with separate production authorization. Neither has been applied by this implementation task.
