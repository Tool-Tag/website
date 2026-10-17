# Driver Loss Agreement Rev 1.0

## Prospective policy

New migration `20261017095441_driver_loss_agreements.sql` establishes an effective timestamp when applied. It is NOT applied remotely. There is no backfill, historical strike count, historical email or automatic financial adjustment. A strike is one newly registered Lost case for its recorded responsible driver. Future failed-stop snapshots prefer the route's assigned driver over the staff actor recording a miss. Existing driver/case records are untouched.

Initial notice is queued by the Lost insert trigger. Its immutable snapshot includes Lost UUID, driver name, occurrence number and provisional cost / To be determined. The initial cost is not treated as final. The registered driver receives the email with the complete agreement text and a link to `/pick-return/loss-agreements/[id]`. Missing driver email leaves the notice queued; authenticated drivers can also open their agreements from the driver header. Driver notifications never use the customer's phone or SMS consent.

First occurrence is a warning acknowledging loss during the process without assigning fault. The driver must accept, and only Owner may authorize continued assignments. Second and later occurrences state monetary responsibility, adjustment to driver pay, and personal payment of any uncovered difference; noncompliance/ban is recorded manually by Owner.

Every document ends with:

Agreement Rev: 1.0
ToolTag - Bandits of the Framing LLC

## Final cost and acceptance

Replacement expense registration or issuance of the Lost refund queues document version 2 with the actual cost. Version 1 text and acceptance stay unchanged. The final version requires separate acceptance before any adjustment could be authorized. This feature does not implement payroll deductions, cash collection or provider transfers.

The named driver must be logged in with an active staff session to accept. Owner can audit but cannot accept on behalf of the driver. Drivers cannot self-authorize eligibility or a ban. No acceptance means no new assignments. After first-warning acceptance, an Owner decision is also required. A later unaccepted final-cost version blocks assignments again. Second/third warnings follow the same monetary rule. A manual Owner ban keeps assignments blocked.

Server route-assignment triggers enforce eligibility on inserts and operator changes; assignment pickers omit or disable ineligible drivers while preserving history. Already assigned routes are not automatically removed; Owner handles operational reassignment. Existing routes are not rewritten by the migration.

## Security and testing

Document table has RLS: named driver or Owner may read; clients have no insert/update grants. Text, cost, occurrence number and version cannot be edited through application RPCs. Private policy/decision tables have RLS and no client grants. Acceptance is bound to auth.uid, active session and exact document ID; it is idempotent and audited. Owner eligibility/ban decisions require a reason and are audited. No user_metadata authorization. Owner eligibility/ban controls remain available when inspecting a historical case because they change the separate driver decision register, never the closed Lost case.

Isolated migration-chain tests cover first-warning acceptance + Owner decision, second/third monetary language, named-driver-only signing, final expense → new immutable document, reblocking until acceptance, assignment denial and manual ban, and nonretroactive historical handling. No production emails, driver agreements or assignments were created during tests.
