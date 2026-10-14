# Dedicated Support V1

`/app/support` is accessible from the top workspace menu and the sidebar. The generic Notifications view is removed; its old URLs redirect to Support. All new labels are English.

- Main tabs **Support / Questions**. Questions contains hello@ inquiries, with no case number in the UI or new outgoing subject. Each main tab has **Open / Resolved**; Open filters **Inbox / Job**. Manually logged phone calls appear under Inbox with channel Call.
- Open rows sort red → orange → green, then longest wait. They show customer, subject, linked Job, latest message, waiting business days and color dot. An answered but still-open case has zero waiting days.
- Clicking a row opens a native modal with customer name, subject/reference and linked Job, and a fixed-height internally scrolling conversation area. Detail loads the full thread in pages, reuses Gmail read/reply controls, displays urgency, links the Job and supports **Mark resolved**. Reading does not clear the response obligation. Failed/unknown outgoing mail does not clear it. Incoming replies reopen the existing case.
- **New case** requires a customer and call notes, optionally a Job belonging to that customer. Request UUID prevents duplicate submissions. Case numbering reuses the existing TT-C counter. No mail is sent when creating a call case.
- Job Issue / Review transitions capture a linked Job-origin case and initial report. Existing active issues are linked during migration without replaying notifications. Job issues use the existing selected quote recipient where available. A successful Gmail reply records the Job response; resolving the case does not release production, change the Job status or settle money.
- Popup/menu urgency counts each Job case once, rather than counting both its Support and Job rows. The latest pending inbound message is the response clock. Existing explicit Job-response records are respected.

Migration `20261014070252_dedicated_support_workspace.sql` is additive. It builds on the un-applied session/attention migration on this branch. Permission `support.inbox` protects reads/mutations; customer/Job directory data is limited to ToolTag. Existing inbox RLS, provider transport, mail failure handling and actor signatures remain in use. No applied migration, Agreement text or production record is modified by this local implementation.

No real customer email is sent during tests. No push, main merge or production migration is performed without separate authorization.

## Closure protocol
The modal header has **Close case** and a separate dismiss X. Close opens a confirmation dialog: **Was the closure protocol followed? Yes / No**. No sends “Is there anything else we can help you with?” through the existing mailbox transport, then leaves the conversation open. Staff reviews the customer's answer; Yes attests that the customer declined further help, sends the final courtesy message and closes only after a durable Sent result. No automatic interpretation of the customer's text is attempted. Direct close RPCs cannot bypass the final-message gate. Pending/unknown delivery or a newer incoming message prevents closure. Reopening clears prior closure attestation. Dismissing the modal never resolves the case.
Cases without a customer email cannot send a reply/closure message; they remain open until contact details/communication can be handled by staff. No fake send result or automatic phone/SMS dispatch is recorded.
