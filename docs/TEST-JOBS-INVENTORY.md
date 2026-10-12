# Existing manual TEST seed — verified 2026-10-12

The requested ~20-job seed already exists in linked production boft-core. It was not recreated: doing so would duplicate fixtures and overwrite the Stripe TEST payment on case17.

Verified:20 jobs with20 distinct IDs,20 quote items,41 physical job items, all customers using `+13852142163`, zero route stops with missing routes.22 distinct TEST customers exist:01–20 each have one Job;21–22 are quote-only fixtures. Their emails use `example.invalid` to avoid emailing real customers. No new customers/jobs/notifications or SMS/email were created/sent during this verification. No real records modified.

Run the read-only `scripts/sql/verify-manual-test-jobs.sql` for current state (Martin's manual actions can advance these fixtures).

| Code suffix (`TEST-J-20261011-`) | Stage verified |
| --- | --- |
| 01 | Pickup Scheduled |
| 02 | Pickup En Route |
| 03 | Pickup Arrived |
| 04 | Picked Up / Received at Shop |
| 05 | Pickup Failed |
| 06 | Pickup Not Scheduled |
| 07 | Return Scheduled |
| 08 | Return En Route |
| 09 | Return Arrived |
| 10 | Delivered / Pending Customer Acceptance |
| 11 | Delivery In Progress |
| 12 | Return Scheduled |
| 13 | Preparing |
| 14 | Engraving |
| 15 | Final Evidence |
| 16 | Ready for Delivery |
| 17 | Return Scheduled; existing Stripe TEST payment preserved |
| 18 | Return Scheduled |
| 19 | Cancellation Requested / Production Hold |
| 20 | Completed / Closed |

TEST phone sharing is already allowed by existing TEST-specific contact uniqueness rules; normal customer uniqueness is unchanged. Sharing a test phone does not itself grant SMS opt-in. Delivery still requires explicit consent and the existing test-mode recipient guard. No consent was invented or enabled by this inventory task.
