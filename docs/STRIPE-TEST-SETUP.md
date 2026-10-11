# Stripe TEST payments

This phase accepts only Stripe TEST keys and TEST events. Live keys are not configured or changed. TEST Checkout is restricted to customers whose names start with TEST-, so simulated payments cannot confirm real customer jobs. Automatic refunds remain disabled.

## Exact environment variables

- STRIPE_SECRET_KEY: the secret key beginning sk_test_. Server-only.
- NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: the public key beginning pk_test_. Hosted Checkout uses a server redirect, so this value is optional to the current adapter, but documented/configured for consistent setup. Never put a secret sk_ key here.
- STRIPE_WEBHOOK_SECRET: the whsec_ signing secret for the registered TEST endpoint below. It is different from the Stripe API secret key.

The initially supplied labels were swapped; the values were assigned by their actual pk_test_/sk_test_ prefixes. Actual keys are stored only in ignored .env.local, never in this document or .env.example. .env.example contains names/placeholders only.

Martin adds these three TEST values to the desired Vercel environments and redeploys. Production variables were not modified by this task. Missing, swapped or live key prefixes keep card Checkout disabled.

## Existing endpoint and events

Endpoint: https://tooltag.martinlab.studio/api/payments/stripe/webhook

TEST webhook ID: we_1UPVXdCb87wF1fzint5lbhBm

Subscribed events:
- checkout.session.completed
- checkout.session.async_payment_succeeded

No new endpoint path or database migration is needed. The handler verifies the raw-body signature and timestamp, rejects live events/non-TEST sessions, requires a paid USD session and valid metadata, and uses the existing confirm_logistics_card_payment RPC for logistics and remaining-balance payments. Existing attempt/session/amount checks and idempotent confirmation are preserved. Other signed TEST event types are acknowledged without processing payment.

## Local test forwarding

Stripe cannot deliver directly to localhost. The official Stripe CLI forwards those two TEST events to http://localhost:3041/api/payments/stripe/webhook.

A CLI listener has its own whsec_ secret. The local test server uses that listener secret as a process-only override. The registered dashboard endpoint secret remains in .env.local for Martin to copy to Vercel. Do not put the CLI listener secret in Vercel.

The listener and Next.js logs are kept privately under /tmp/tooltag-stripe-cli. Local Gmail/SMS/refund modes stay inactive. A Supabase service-role server key is required to verify the resulting TEST ledger entry; it is not exposed to the browser or committed. Only the two explicitly authorized Supabase connection variables may be exported for this test.

Use Stripe test card 4242 4242 4242 4242, a future expiry and any three-digit CVC. Only a TEST- job is used. A success redirect is not evidence of payment: the signed webhook must confirm the attempt, then repeated delivery must not produce an extra collection.

## Current verification status

Stripe API key was validated with livemode=false. The TEST endpoint above was registered successfully. Typecheck/lint/build and automated tests pass. The real 4242 Checkout + local webhook/ledger test requires SUPABASE_SERVICE_ROLE_KEY in ignored .env.local; Vercel marks that value sensitive and does not allow retrieval. Until supplied, do not claim real end-to-end completion or a payment/session ID.
