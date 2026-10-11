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

SMS follows existing notifications for: route departure, next-stop en route, three stops remaining (existing approximate ETA text), arrival/five-minute wait, scheduling/rescheduling, quote/job/Agreement confirmations, completion, payment and cutoff reminders, route interruption and shop pickup. Email templates/events are preserved. All alert SMS use the short English template: Your order {job_code} moved to {stage}. Details: {status_link}. The worker resolves the existing Job status link. Before a Job exists it uses the Quote number and existing Review & Accept link. Email content is unchanged. Event labels include Driver En Route, 3 Stops Away, Driver Arrived, Payment Due and Confirmed; details stay in tracking.

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
