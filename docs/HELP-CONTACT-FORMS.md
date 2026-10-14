# Help contact cards

The first two panels on `/help` match the existing panel style. Questions shows **Send us your question or inquiry** and opens Name / Phone / Email / Message. Support opens Name / Email / Phone / Job number / Message. Phone and Job reference are optional; all new copy is English.

Both forms create an Inbox-origin conversation in the matching Support/Questions mailbox, one inbound message and the existing automatic acknowledgment queue. Support returns its generated TT-C reference; Hello has no case number or response-time promise. No Customer, Quote, Job, Sale or payment is created or changed.

Public submission uses a same-origin POST, per-form HttpOnly nonce, payload validation, size limits, honeypot, transactional request UUID deduplication and per-IP/email rate limits. Privileged database RPC is service-role-only; no service key reaches the browser. Retry after a lost response returns the same submission. New form openings create new nonces.

Customer matching uses the existing personal/company email and only a unique match is linked. A submitted Job number is linked only to that matched customer. Otherwise its reference is retained for staff review without revealing Job details or existence to the public. Staff modal displays the contact phone and unverified reference.

Both phone fields include the established two unchecked SMS consent/policy checkboxes and policy links. Submission works without phone or consent. Consent is stored with the submitted disclosure for staff review; anonymous contact submission never overwrites/grants SMS consent on an existing customer.

Migration `20261014073146_public_help_support_forms.sql` is additive and follows the acknowledgment migration on this branch. No production migration, real email, push or deployment is performed by this implementation.
