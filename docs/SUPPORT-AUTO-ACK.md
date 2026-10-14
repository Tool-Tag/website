# Automatic Support / Questions receipts

Only newly ingested customer messages enqueue receipts. Existing stored messages are not replayed. Gmail ingestion deduplicates provider IDs; each inbound message has at most one queue row and a fixed outgoing Message-ID.

Support creates the existing TT-C case number at receipt (not a second SUP counter), retains that number for later messages in the same conversation and sends:

`Hi {linked customer name or there}, we've received your inquiry and it will be reviewed within 1-2 days. Your case number is #{actual case number}. Thank you for your patience.`

Hello / Questions keeps no case number and sends:

`Hi {linked customer name or there}, we've received your message and we'll get back to you as soon as possible. Thank you for reaching out.`

The existing five-minute Gmail inbox worker claims up to ten receipts per pass after ingestion, using the existing logical mailbox addresses, OAuth transport and thread headers. Sending requires production inbox enablement and live mail mode; test-delivery mode does not dispatch automatic customer receipts. Local/test mode never sends real receipts.

Receipts are visibly marked automatic. They do not clear response clocks, mark Job issues answered, move New cases into the human-replied state or satisfy closure. Actual staff responses remain the SLA boundary. An ambiguous automatic receipt does not block a new staff response or the separately verified closure protocol. A queued receipt is cancelled if staff already answered or resolved its conversation before delivery. Ambiguous sends are checked against Gmail by deterministic Message-ID and never automatically resent. Definitively failed sends remain recorded Failed rather than silently replayed.

Incoming Auto-Submitted/bulk/list messages remain available to staff but do not get receipts. Outgoing receipts include Auto-Submitted and X-Auto-Response-Suppress headers to prevent loops. Synthetic Job reports and logged calls do not email a receipt; actual subsequent Gmail replies can.

Migration `20261014072226_support_auto_acknowledgment.sql` is additive, follows the dedicated workspace migration, and has worker-only mutation RPCs and permission-protected read RLS. No production migration or Gmail send was performed for this implementation.
