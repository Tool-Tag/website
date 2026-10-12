# Phase B — Support / Hello inbox

Branch: `feature/roles-support-inbox`. Local feature only until audit/rollout approval. Phase C has not started.

## What this adds

Workspace **Notifications** navigation (requires `support.inbox`) with Support, Hello, Open cases and History tabs. New inbound conversations stay in their department until replied to. First reply allocates `TT-C-YYYY-#####` using a locked yearly counter. Successful replies move the case to Open. Close moves it to History; incoming replies reopen closed cases. New conversations and unread case responses contribute one attention count per conversation, not per message. Reading clears incoming unread messages through the last displayed timestamp. A new unanswered conversation continues requiring attention until replied to.

Replies use the original receiving alias for From and Reply-To, a `[TT-C-YYYY-#####] Re: original` subject, RFC In-Reply-To/References and the user's staff display name as signature (ToolTag Team if not configured). Gmail thread ID is the primary correlation; folio/header fallback requires matching original sender and department. Both old and new Gmail thread IDs can map to one case. Existing Quotes/Billing outgoing transports, templates, queues, recipients and Agreement are unchanged.

## Google one-time setup (after audit)

Use the existing Workspace mailbox OAuth client and refresh token, not a password/service account. Enable Gmail API and authorize BOTH:

- `https://www.googleapis.com/auth/gmail.send` (existing sending scope)
- `https://www.googleapis.com/auth/gmail.readonly` (new inbox read scope)

**Google classifies gmail.readonly as Restricted**, stronger than merely sensitive. Use an Internal Workspace consent app where eligible; if External, review Google's verification/restricted-scope requirements before production. A refresh token previously issued for send-only does not acquire read privileges automatically. Re-consent with offline access, preserving send scope, and replace only the server-side refresh token. Do not paste credentials into GitHub, docs or UI.

Confirm this SAME mailbox receives support@ and hello@ and has both configured as Gmail Send mail as aliases. A scope change is not a new Workspace inbox. Do not revoke the old working refresh token until replacement read/send authorization is verified. No Google authorization performed by this implementation.

## Environment

Existing server-only values remain:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REFRESH_TOKEN`
- `NEXT_PUBLIC_SUPABASE_URL`
- `SUPABASE_SECRET_KEY` or `SUPABASE_SERVICE_ROLE_KEY` for reply delivery results; current cron already uses service role.
- `CRON_SECRET` (existing worker Bearer authentication)

New:

- `TOOLTAG_SUPPORT_INBOX_ENABLED=true` only after migration, OAuth and test-recipient review.
- `TOOLTAG_INBOX_SUPPORT_ADDRESS` (default `support@tooltag.martinlab.studio`)
- `TOOLTAG_INBOX_HELLO_ADDRESS` (default `hello@tooltag.martinlab.studio`)

Existing outbound safety remains: `TOOLTAG_MAIL_MODE=preview` cannot send. `test-delivery` sends only to `TOOLTAG_MAIL_TEST_RECIPIENT`; `live` uses the real correspondent. Inbox read and reply are **always disabled in development and Vercel preview**, even with copied credentials. No real Gmail calls were made in local automated tests; mocks and local DB fixtures only.

The read flag permits incoming import in production even if sending stays preview. Missing OAuth/flag disables import. Missing schema is returned as unavailable; read/scope failure appears in inbox sync status without interrupting existing customer notifications. Aliases must be distinct valid mailboxes; Quotes and Billing aliases are reserved and cannot be configured as inbox departments.

## Database and rollout

New additive migration: `20261012044838_support_inbox_cases.sql`, after approved Phase A `20261012013207_roles_permissions_driver_scope.sql`. Neither has been applied by this task. No applied migration was edited. No production SQL, emails, auth changes, cron activation or deployment were performed.

Tables: public `support_conversations`, `support_threads`, `support_messages`; private `support_case_counter`, `support_sync_state`. Public tables have RLS and SELECT-only authenticated grants; mutations go through explicit guarded RPCs. Non-support/disabled users cannot read inbox rows. Worker ingest/result/checkpoint RPCs are service-role-only. No general customer-table or Gmail credential access is granted to Support users. Customer matching is by sender email against personal/company email within ToolTag; if ambiguous, leave unlinked. Customer links only show when `customers.view` is also held.

Existing `/api/cron` worker calls the new sync independently alongside existing dispatchers. Existing `tooltag-route-worker` pg_cron schedule `*/5 * * * *` is sufficient; **no second cron and no Vercel Hobby 5-minute cron**. Verify the existing schedule and matching Bearer secret at authorized rollout using `scripts/sql/enable-route-worker.sql` only if missing. Do not change it merely for this phase.

Initial cursor is migration time minus five minutes (plus five-minute scan overlap). This intentionally avoids importing all historical mail. Each run reads at most one page (50 messages), keeps a fixed scan end, stores its next page token and checkpoint, uses a six-minute lease, and stops after a bounded time budget. Duplicates are ignored by Gmail message ID. A failed page retains its scan window for retry; invalid page tokens restart that same window. Backlog can take multiple five-minute runs. No Gmail labels are changed and mailbox read/unread state is not modified.

## Threading caveat

Gmail requires matching subjects for the same thread. Adding the required case folio changes the first subject, so Google may create a new thread. The implementation supplies the original thread ID and reply headers; on a definite Gmail 400 only, it can send without thread ID. Both thread IDs are then mapped to the same ToolTag case. Never retries an ambiguous send. See https://developers.google.com/workspace/gmail/api/guides/threads and https://developers.google.com/workspace/gmail/api/auth/scopes.

## Delivery safety

Reply is persisted as Sending before Gmail is called, with a unique request UUID, deterministic RFC Message-ID and stored signature/body. Double submission and concurrent unresolved sends are blocked. Definitive rejection is Failed and allows a fresh retry; timeout/5xx/malformed success is Unknown, never auto-resend. The worker searches Gmail Sent by exact RFC Message-ID for stale Sending/Unknown messages, then confirms actual provider ID/thread. If no match, it stays Unknown for operator investigation, not Failed. Do not clear Unknown and resend without verifying the mailbox; Gmail does not provide a send-idempotency API.

Message bodies render as escaped text, never received HTML. HTML-only email is reduced to text. Attachments are not imported in this phase. UI shows at most 100 recent conversations per tab and 200 messages per selected conversation. No secrets or bodies go into action audit logs. Close/reply preparation are actor-audited.

## Validation and remaining manual steps

Local tests cover permission model/RLS, disabled staff, service-only ingest, Gmail deduplication, customer auto-link, case numbering/signature, closing/reopening, thread/subject/header fallbacks, different-sender isolation, worker lease/checkpoint, Unknown reply protection, MIME routing, test-recipient guard and Gmail failures. Run typecheck/lint/tests/build before local commit.

After explicit rollout approval: apply Phase A then B, verify new tables/RPCs and RLS on the linked project; configure refreshed Google scopes and aliases; set flag in production; verify existing pg_cron/Bearer; use ONE intended internal test correspondent to receive a Support/Hello reply and verify both thread IDs/case status. No live test or production-readiness claim until that succeeds. Phase C settings tab organization remains deferred for its separate approval.

Local verification complete: typecheck, lint, 123 tests (33 CJS + 90 TS), production build and whitespace check passed on Node 24.11.1. After the SQL concurrency safeguard, all 59 DB tests passed again. CI remains Node 22 and now includes this feature branch trigger; it has NOT run because no publication occurred. Waiting for phase audit; Phase C not started.
