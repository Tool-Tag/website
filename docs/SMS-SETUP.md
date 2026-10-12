# ToolTag SMS setup — AWS SNS

SMS is a separate transactional channel alongside existing Gmail notifications. It starts disabled and does not replay historical notifications. No AWS credentials are included in source control. No real SMS was sent during implementation.

## Exact values Martin must obtain

| Value | Obtain from | Paste into |
|---|---|---|
| AWS Access Key ID | IAM → dedicated application user → Security credentials → Create access key | Settings → SMS → AWS Access Key ID **or** Vercel `AWS_ACCESS_KEY_ID` |
| AWS Secret Access Key | Shown once when that IAM access key is created | Settings → AWS Secret Access Key **or** Vercel `AWS_SECRET_ACCESS_KEY` |
| Region | The AWS region where SNS SMS and the origination identity are configured, e.g. `us-west-2`; use the actual region | Settings → AWS region **or** Vercel `AWS_REGION` |
| Origination number | AWS End User Messaging SMS → Phone numbers → registered SMS-capable number; international E.164 format | Settings → Origination number **or** Vercel `TOOLTAG_SMS_ORIGINATION_NUMBER` |
| Test recipient | Martin's own mobile number, E.164, verified in the SNS sandbox | Settings → Test recipient **or** Vercel `TOOLTAG_SMS_TEST_PHONE` |
| Session token, only for temporary credentials | AWS STS session credentials; expires and must be refreshed | Settings → AWS Session Token **or** Vercel `AWS_SESSION_TOKEN` |

Use a dedicated IAM identity, never an AWS root access key. This adapter needs `sns:Publish` and `sns:CheckIfPhoneNumberIsOptedOut`. For direct phone-number publishing these actions use `Resource: "*"`; restrict the IAM policy to the configured region through `aws:RequestedRegion`. No SNS Topic ARN is required. The server checks opt-out before every Publish and never calls the AWS OptInPhoneNumber API.

## Application/server values

These are server-only Vercel Environment Variables, **never `NEXT_PUBLIC_`**:

- `TOOLTAG_SMS_MODE=test` initially; switch to `live` only after the test and AWS registration are complete. Default without this value is `preview`, which performs no network send.
- `TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY`: needed only to paste AWS credentials into app Settings. Generate a random 32-byte key, base64 encoded, e.g. `node -e 'console.log(require("node:crypto").randomBytes(32).toString("base64"))'`. Paste the resulting value into Vercel. Keep a secure backup; replacing it makes previously saved credentials unreadable until re-entered. Never commit the value or share it in chat. Settings encrypts credentials with AES-256-GCM and a fresh nonce before storage. They are never returned to the browser.
- `TOOLTAG_PUBLIC_URL=https://tooltag.martinlab.studio` — existing public URL, used for safe customer action links.
- `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` — existing server connection; do not replace. The latter remains server-only.
- Optional `TOOLTAG_SMS_MAX_PRICE_USD`: SNS maximum price per message; default `0.50`. AWS may decline messages exceeding the price limit.
- Optional `TOOLTAG_SMS_ALLOW_LOCAL_LIVE=true`: explicit local/preview network opt-in. Leave absent in normal development. `NODE_ENV=production` alone never enables real SMS locally. Automatic customer sending additionally requires mode `live` and the saved enabled toggle.

Environment AWS keys/region/origination/test recipient take precedence over corresponding Settings values. Use one credentials source; do not supply only half of an environment key pair. To rotate saved credentials, enter both keys; blank credentials fields preserve the existing encrypted value. Secrets are never prefilled or displayed.

## AWS one-time setup

1. Choose an SMS-supported AWS region. In SNS → Text messaging (SMS), verify Martin's test mobile number in the sandbox.
2. Obtain/register an origination identity through AWS End User Messaging SMS (10DLC, toll-free or short code as appropriate). Complete the relevant US registration/verification and ensure its region matches `AWS_REGION`. The implementation sends `AWS.MM.SMS.OriginationNumber` and `AWS.SNS.SMS.SMSType=Transactional`.
3. Verify AWS-managed STOP/HELP behavior for that identity. The app respects SNS account opt-outs using CheckIfPhoneNumberIsOptedOut and provides website withdrawal in customer tracking. It does not override an AWS STOP or opt a phone back in automatically. Configure AWS's applicable two-way/opt-out support before enabling live service.
4. Check the AWS spending limit and, before customer use, request production access out of the SNS SMS sandbox. Sandbox accounts can send only to verified destination numbers.
5. Optionally enable SNS SMS delivery-status logs in CloudWatch to inspect carrier delivery. An SNS MessageId means AWS accepted the message, not proof the handset received it.

Official references: [SMS sandbox](https://docs.aws.amazon.com/sns/latest/dg/sns-sms-sandbox.html), [origination identities](https://docs.aws.amazon.com/sns/latest/dg/channels-sms-originating-identities.html), [sending SMS and attributes](https://docs.aws.amazon.com/sns/latest/dg/sms_sending-overview.html), [provider opt-outs](https://docs.aws.amazon.com/sns/latest/dg/sms_manage.html).

## Enable and test

1. Apply additive migration `20261011181327_sms_sns_notifications.sql` before activating this feature. It creates private settings, consent evidence and per-notification delivery records with RLS and restricted RPCs.
2. Configure the server variables, redeploy, then open `/app/settings` as a ToolTag admin. Paste the AWS values or configure them in Vercel. Save with customer SMS **off**.
3. Confirm the configured test number belongs to you and check the test-consent checkbox. Click **Send test SMS**. Only the saved test recipient is allowed; posted arbitrary destinations are ignored. A 90-second database-enforced cooldown prevents repeat clicks.
4. Confirm receipt on that phone and check AWS delivery logs/STOP behavior. No test sends to customer numbers.
5. Change `TOOLTAG_SMS_MODE=live`, redeploy, then enable customer SMS in Settings. Only notifications created from activation onward can send. Do not activate while AWS remains restricted to sandbox destinations.

## Consent, events and failure behavior

The optional checkbox in Review & Accept is separate from the unchanged Customer Agreement. It is initially unchecked and discloses automated transactional messages, variable frequency, possible rates, optional consent and STOP/HELP. Consent stores the exact disclosure, version, phone, flow/customer relationship, timestamp and source. Existing customers are not opted in automatically. Each quote/job flow requires consent for its explicit SMS number. Customers can withdraw through SMS preferences on their review or tracking page; website withdrawal revokes ToolTag consent across records for that number. A valid secure capability token is required; staff cannot assert consent on a customer's behalf.

SMS follows existing notifications for: route departure, next-stop en route, three stops remaining (existing approximate ETA text), arrival/five-minute wait, scheduling/rescheduling, quote/job/Agreement confirmations, completion, payment and cutoff reminders, route interruption and shop pickup. Email templates/events are preserved. All alert SMS use the short English template: ToolTag: Your order {job_code} moved to {stage}. Details: {status_link}. The worker resolves the existing Job status link. Before a Job exists it uses the Quote number and existing Review & Accept link. Email content is unchanged. Event labels include Driver En Route, 3 Stops Away, Driver Arrived, Payment Due and Confirmed; details stay in tracking.

Missing phone, absent consent, TEST customers whose SMS number differs from the configured test recipient, disabled mode and expired messages are skipped with a private delivery-log reason. Consent is checked again when claiming a queued message; SNS opt-out is checked immediately before publishing. Arrival messages expire after five minutes, nearby messages after thirty minutes, en-route messages after six hours and other messages after twenty-four hours from their due time. Old or skipped events are never replayed. Pending future messages queued before a later activation are skipped.

The existing five-minute authenticated cron worker drains SMS, and current driver/customer actions also dispatch it independently of Gmail configuration. Settings shows the latest twenty SMS outcomes without exposing secrets or customer phone numbers.

No provider auto-retry: direct SNS SMS does not accept an idempotency token. A network timeout/uncertain acceptance is recorded as `Unknown`; interrupted claims become `Unknown` rather than being re-sent. Definite rejects are `Failed`; provider acceptance is `Sent` with MessageId. Investigate AWS before any manual resend. SMS errors do not fail email delivery, scheduling or customer actions.

## Verification

Automated tests mock AWS; no real phone was contacted. Tests cover encryption, missing credentials, local/test restrictions, transactional/origination attributes, SNS opt-outs, unknown versus rejected outcomes, safe links, token isolation, consent withdrawal, secret concealment, role gates and one-shot queue claims. Keys and AWS registration are still required for a real test and live carrier delivery.

## TEST fixtures and shared phones

Administrator-created TEST- customers remain separate customers and may share contact details. Real ToolTag customers require unique personal email (case/whitespace insensitive) and phone (format and US +1 insensitive), enforced by indexes and insert/update validation. Existing real customer data is not merged or rewritten.

TEST- route/payment alerts may send in `test` mode, but only to the configured test recipient, with recorded opt-in and provider STOP checks. They remain disabled until SMS is enabled with credentials. Historical/skipped notifications are never replayed. Changing the test recipient blocks previously configured TEST flows for another number. Local sends still require explicit local network opt-in.

Current TEST fixtures use the shared test recipient configured in Settings. Martin's explicit authorization is recorded as `admin_test_authorization` for existing TEST flows only; no real customer was opted in. To exercise their automated events, use test mode and enable SMS after configuring AWS. This does not replay old events. New TEST flows still need explicit consent.

## Short customer SMS format

No free-form email text, HTML, help footer or long explanations are copied into alert SMS. Plain English ASCII labels preserve GSM-7 encoding. Aim for one 160-character segment; the existing capability URL and identifier are never truncated. Longer full links can require multiple segments. No URL shortener or token rotation is introduced. SNS STOP handling and existing explicit consent/withdrawal remain enforced. One-time verification codes and admin test messages keep their dedicated formats.

## Public phone forms / policy links (2026-10-12)

Optional unchecked SMS consent now appears in Get Tagged (desktop modal and standalone/mobile form), Review & Accept/Quote, status SMS preferences and the public cancellation/service lookup. Get Tagged includes an optional SMS mobile field so a company landline need not receive alerts. The checkbox applies to the selected mobile number, not automatically to every company contact. Staff-only customer/contact, business settings, AWS origination and test-number fields are NOT customer consent surfaces; merely entering a number there never subscribes a customer.

Both approved published HTTPS URLs are required in Vercel and the next rebuild:

- `NEXT_PUBLIC_TOOLTAG_PRIVACY_URL`
- `NEXT_PUBLIC_TOOLTAG_TERMS_URL`

No approved URLs/pages were present in this repository at implementation time; these values remain blank, with no invented legal text, no broken placeholder links and no Customer Agreement changes. When missing, NEW subscriptions are disabled in UI and rejected by normal application grant actions; requests/quote acceptance still work without SMS. Existing subscribed customers can retain their same number or revoke consent. Configure actual approved URLs and rebuild before expecting new SMS opt-ins.

The Get Tagged payload stores explicit consent/disclosure/policy URLs with the receipt. The additive receipt trigger attaches consent when the Draft Quote flow is created, including delayed admin matching. It does not generate/replay SMS notifications or overwrite an existing flow choice. Optional cancellation lookup uses the entered customer number and only records consent after the existing exact name/email/phone lookup matches active services; its new RPC is service-only. Ordinary lookup without SMS retains the existing RPC/behavior.

Additive migration `20261012175943_public_intake_sms_consent.sql` applied and verified via connector in boft-core as history version `20261012180626`, name `20261012175943_public_intake_sms_consent`. Original applied migration files unchanged; no history repair. No real SMS/email was sent for implementation/testing. Local typecheck/lint/128 tests/build pass. Tests cover unchecked/default consent, policy URLs, intake-to-Draft-flow recording, idempotence, no replay and lookup recipient/service-role restrictions.

## October 12: public toll-free opt-in evidence

Get Tagged now has an optional Phone field and two separate unchecked checkboxes: the approved delivery/shipping SMS disclosure and acceptance of Terms/Privacy. Without either checkbox or a phone, the request still submits; SMS enrollment requires both and a valid mobile number. Published `/terms` and `/privacy` are the default policy links. The intake receipt and consent audit preserve the disclosure, policy URLs and timestamp.

Status shows **Get Notifications By SMS** for non-subscribers. Its modal requires both checkboxes and a mobile number, then **I accept**. A new status grant records its timestamp, skips prior pending notifications, and queues one SMS-only welcome. Repeated acceptance does not duplicate it. Later events wait until SNS accepts that welcome; failed/uncertain welcomes require operator review rather than automatic resend. Earlier events are never replayed. STOP/provider opt-out and existing disabled/test/live protections remain in force.

Migration: `20261012233000_sms_optional_phone_status_opt_in.sql`. Apply before publishing the corresponding app changes. This does not activate AWS or send any SMS by itself. AWS toll-free approval, origination registration, keys, mode and the SMS toggle remain necessary for real delivery. A saved website consent is not a guarantee of handset delivery.
