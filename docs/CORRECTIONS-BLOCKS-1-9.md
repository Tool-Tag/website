# Corrections blocks 1–9

## Local implementation

Branch: `feature/corrections-blocks-1-9`. No production changes have been made.

- Shared Electric Blue actions, Gold pagination, X dialog dismissal, English operational UI. Driver policies alone retain the requested Spanish toggle.
- Finance main tabs, modal transaction creation, Trip/Mileage list and transaction type.
- Get Tagged review hides SMS costs; reason-required rejection saves Rejected/History and queues an English email once.
- Public `/pick-return/policies-and-conditions`; old policy index redirects; named driver loss agreements remain authenticated.
- Per-block agreement freezes policy and approved commercial terms, block, driver, date and ordered stop manifest. Only the assigned eligible driver can accept. Confirmation deadline is two hours before the route. Insurance/registration expiry dates are driver attestations, not independent document verification. Expired dates fail acceptance; changes to the block invalidate the acceptance. Assigned blocks cannot depart without current acceptance. Existing unassigned staff-operated routes retain their existing behavior.
- Driver block starts at the shop one hour before the route; driver cancellation deadline is one hour before that block. TT cancellation after the two-hour deadline compensates $10 before shop arrival or $20 after shop arrival. No-show terms: one month, three months, permanent ban. These are agreement terms; this change does not create automatic payroll, cancellation compensation or no-show adjudication.
- Lost replacement purchases retain the actual image upload and server guard requiring a stored receipt for $75 or more; regression coverage explicitly rejects missing proof.
- Refund creation beside the state tabs; Support lists/filters; detached Equipment registration action.
- Optional SMS dispatch never fails a saved business action. Without configuration/activation it skips safely. Production activation uses settings, AWS credentials and `TOOLTAG_PUBLIC_URL`; explicit `TOOLTAG_SMS_MODE` overrides the mode. Local/test sending still requires explicit enablement and configured test-recipient restrictions.
- Request-level opt-in works before a Customer/Quote exists. Consent, both checkbox acceptance, disclosure and policy URLs are checked. Request SMS uses the existing secure request status link and includes welcome/STOP instructions. No historical SMS are replayed. Accepted request SMS has a private tariff/provider ledger and transfers exactly once into Quote/Job costs on conversion. Unconverted request costs remain in the request ledger; automatic Finance expense posting for requests that never become Quotes is outside this change.

## Additive migrations (local only)

1. `20261017223043_request_rejection_history.sql`
2. `20261017223437_sms_workflow_readiness.sql`
3. `20261017225943_driver_block_acceptance.sql`
4. `20261017230133_request_sms_readiness.sql`

Apply in order only after review and production authorization. No applied migrations or Customer Agreement text were edited.

## Validation

Local checks cover English rendering helpers, request rejection/idempotency, optional SMS failures, consent/test routing, accepted-cost transfer, immutable driver agreement snapshots, changed-manifest invalidation, vehicle validity and receipt enforcement. No customer email/SMS was sent. See the handoff for final check results and any remaining review notes.
