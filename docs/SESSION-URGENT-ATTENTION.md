# Staff session lifetime and login attention

## Session boundary

ToolTag staff sessions expire four hours after `auth.sessions.created_at`. Token refresh, page activity and navigation do not extend the deadline. The application checks the authenticated session on the server, middleware and central ToolTag RBAC/RLS predicate. An open staff screen also checks its deadline and redirects to a local-session sign-out route; sleeping tabs check when they become visible again. Other device sessions are not signed out.

Supabase Auth configuration and production data are not changed by this task. Customer token links retain their existing expiry. Non-ToolTag RBAC behavior is preserved. Missing or expired staff session records fail closed. Deployment requires the additive migration before this application version.

## Login popup

Owner and an active custom role named **Manager** (case-insensitive) receive the summary once per Auth session on their first staff workspace/driver screen. It combines pending Refunds, customer response obligations and Lost records in Red / Orange / Green bands, with category subtotals and links. Browser-local dismissal is presentation only; it does not resolve records or grant access. No Manager role or broader permissions are automatically created.

### Confirmed counting conventions

- Refunds: inclusive Denver **weekday** days (Monday–Friday) from `requested_at`: days 1–2 green, 3–4 orange, 5+ red. Completed/cancelled or fully processed entries are excluded.
- Customer responses: inclusive Denver **weekday** days (Monday–Friday; holidays are not a separate calendar): day 1 green, 2–3 orange, 4+ red. Overdue items remain red.
- Support/Hello: oldest inbound message after the latest successfully **Sent** outbound response, in an open conversation. Reading a message, preparing a draft or a failed send does not clear the obligation. Closing the case removes it; a new inbound reply reopens it through the existing inbox behavior.
- Job issues: entering `Issue / Review` starts a dedicated timestamp so unrelated updates do not reset the clock. Staff with `jobs.manage` can explicitly confirm an actual customer response on the Job; this records the actor and audit event, does not send mail and does not resolve the issue. A new issue cycle resets the clock. Existing active issues use their last known update time as the initial approximation; no notification is replayed.
- Lost: always red while the Job remains Lost, regardless of age.

Support conversations and Job issues are distinct obligations; no unreliable email/Job matching is used to collapse them.

## Security / rollout

New authenticated RPCs use empty search paths and explicit grants. Session introspection is restricted to the caller's authenticated Auth session. Attention reads require active Owner/Manager eligibility and return only ToolTag records. Links retain the destination's existing permission checks. RLS and mutating staff RPCs use the expired-session guard through `private.staff_active`.

Migration: `20261014062501_session_timeout_urgent_attention.sql`. No applied migration or Agreement text changed. No migration applied to production; no main merge or deployment performed by this task.
