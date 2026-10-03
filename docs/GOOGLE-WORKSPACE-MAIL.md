# ToolTag · Google Workspace mail

## Implementation

Gmail API `users/me/messages/send`, using OAuth 2.0 offline access and only the `https://www.googleapis.com/auth/gmail.send` scope. The refresh token belongs to the main Workspace account with the configured Send As aliases. No passwords, SMTP credentials, or domain-wide delegation are required.

Existing quote and confirmation templates are retained. Quote creation/acceptance succeeds even when mail is unavailable. Viewing the email preview never sends. From and Reply-To are centralized in `src/lib/integrations/mail-routing.ts`.

- Quotes: quotes@tooltag.martinlab.studio
- Payments and refunds: billing@tooltag.martinlab.studio
- Issues and claims: support@tooltag.martinlab.studio
- Job completion and other customer reminders: notifications@tooltag.martinlab.studio
- General contact: hello@tooltag.martinlab.studio
- Purchases: purchases@tooltag.martinlab.studio, reserved for vendor workflows; never selected for customer notifications.

Current event producers for quotes, agreement confirmation, payment receipts, ready-for-delivery, completion and issues use the existing queue. Future events can supply an explicit `notification` template with `subject`, `text`, and recipient; no new business events are invented. Internal accounting/Drive events are not mailed. Existing completion links created before this migration cannot be reconstructed and retain the manual delivery flow.

## Vercel Production variables

Required secrets (never NEXT_PUBLIC; do not commit or paste into chat):

- GOOGLE_CLIENT_ID
- GOOGLE_CLIENT_SECRET
- GOOGLE_REFRESH_TOKEN
- SUPABASE_SERVICE_ROLE_KEY (server worker, acceptance confirmations and scheduled notifications)
- CRON_SECRET (authenticated daily scheduled worker)

Configuration:

- TOOLTAG_PUBLIC_URL=https://tooltag.martinlab.studio
- TOOLTAG_MAIL_MODE=preview (safe default), test (no delivery), test-delivery (only the exact configured test recipient), or live (customer delivery)
- TOOLTAG_MAIL_TEST_RECIPIENT: required for test-delivery; use a test customer already addressed to this mailbox. Real customer links are never redirected to a test inbox.
- TOOLTAG_MAIL_ALLOW_LOCAL_SEND=false; only explicit true permits real local delivery.
- TOOLTAG_MAIL_<DEPARTMENT>_FROM / _REPLY_TO / optional _NAME. Departments: QUOTES, BILLING, SUPPORT, NOTIFICATIONS, HELLO, PURCHASES. Defaults appear in .env.example.

Redeploy after setting variables. Live mail is blocked in Vercel preview deployments. The daily cron sends up to five pending messages per invocation; interactive quote actions also dispatch their own messages. Gmail accepting a message is recorded as Sent with its provider ID; this does not prove inbox delivery or reading.

## Google one-time setup, if credentials are not already available

1. Enable Gmail API in the Google Cloud project owned by your Workspace organization.
2. Configure an Internal OAuth application for the organization where appropriate, and a Web application OAuth client.
3. For a one-time authorization with Google's OAuth Playground, register https://developers.google.com/oauthplayground as an authorized redirect URI. In Playground settings enable “Use your own OAuth credentials” and enter that client ID/secret.
4. Request offline access with scope https://www.googleapis.com/auth/gmail.send. Authorize the main Workspace mailbox that has the Send As aliases, not a nonexistent separate alias account. Exchange the code and securely place its refresh token in GOOGLE_REFRESH_TOKEN in Vercel.
5. If Workspace app access control blocks consent, the administrator must allow this OAuth client/scope. Confirm all sending aliases are verified under Gmail Send mail as.

References: https://developers.google.com/identity/protocols/oauth2/web-server and https://developers.google.com/workspace/gmail/api/guides/sending.

## Failure handling

A database claim prevents concurrent sends. OAuth failure or Gmail rejection records a sanitized failure code. A timeout/disconnect after submission records GMAIL_DELIVERY_UNKNOWN. A process interruption leaves Queued. None is automatically resent, because Gmail has no send-idempotency guarantee. An administrator must reconcile unknown outcomes with Gmail Sent mail before resetting a failed/queued record. The stable Message-ID is diagnostic, not a delivery deduplication promise.

No customer acceptance deadline starts from a queued or failed email. Completion delivery accepted by Gmail records the timestamp, establishes the existing three-day deadline, and schedules the reminder.

## Release status

The user stopped local validation and requested implementation without further local tests. Full final type/lint/test/build and end-to-end inbox verification are not claimed. No customer email was sent during implementation. At inspection, Vercel website/ToolTag had only the two public Supabase variables; OAuth credentials were not present there. Gmail aliases/DKIM being configured is separate from authorizing this application's API access.

Migrations: 202610030003_engraving_paint.sql and 202610030004_gmail_delivery.sql. Neither rewrites accepted quotes or BOFT records. Paint is captured per engraving and charged $2 per colored physical piece, once even when several engravings on it have paint. Logo adaptation remains separate.

Release: Vercel deployment dpl_4excFAhRhSx47sZBXH6M6Zym7JNs completed its production build and TypeScript stage successfully. Both additive migrations were applied to the linked Supabase project. This remote deployment build is not a local functional test or proof of Gmail delivery. Changes remain uncommitted locally for GitHub Desktop.
