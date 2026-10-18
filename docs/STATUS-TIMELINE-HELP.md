# Status timeline and job-linked Help

## UI

The customer job timeline uses one non-wrapping horizontal row. Completed checkmarks, the gold current step, Upcoming pill/expanded steps and the final Completed node stay inline. Narrow screens scroll horizontally rather than cascading. The Completed toggle sits below, left-aligned. Progress and Denver timestamps remain unchanged.

This Service → Help opens a native accessible dialog without navigation. The customer enters only a message; trusted identity and job data are resolved from the existing status token. Success replaces the composer with the approved confirmation text and case reference. No customer-facing Spanish was added.

## Support connection

New additive migration: `20261018204325_status_job_support_inquiry.sql` (not applied to production).

`submit_status_support(text,uuid,text)` authorizes against the hashed job-status bearer. It creates a Support/Job-origin email conversation linked to the job and customer, using the existing case-number allocator and inbound-message acknowledgment trigger. Staff replies and closure use the existing Support system. The saved context includes job details, customer identity/project email, quote, items, logistics and evidence/document references; the staff modal provides the context snapshot and its existing live job link. No job lifecycle state is changed merely by asking for help.

The database derives the reply address from the accepted project recipient (customer email fallback), never from browser-supplied identity. Submission UUIDs deduplicate retries. Per-job advisory locking and a five-inquiries/day cap bound abuse. Existing Support RLS protects the snapshot; public callers receive only a case reference. The existing inbox worker sends acknowledgments when Gmail is enabled; the case itself is saved even when email is disabled.

## Verification

Browser fixture: completed/current/upcoming/final nodes all shared the same top coordinate before and after expanding Upcoming. Help opened in place, accepted text and enabled Send inquiry. No real customer email was sent. Temporary fixture was removed.

Isolated database test: valid status token creates a job-linked case plus one acknowledgment; retry creates no duplicate; context has the correct job/items; invalid token fails; daily cap enforced; job status unchanged. Typecheck/lint/full tests/build run before publication. Production migration application and live delivery remain separate deployment checks.

This branch builds on PR21, which builds on PR20; neither dependency is merged by this task.
