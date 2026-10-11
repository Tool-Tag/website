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

The existing endpoint path is preserved. An additive migration adds a restricted worker lookup and isolated TEST accounting, without granting table access. The handler verifies the raw-body signature and timestamp, rejects live events/non-TEST sessions, requires a paid USD session and valid metadata, and uses the existing confirm_logistics_card_payment RPC for logistics and remaining-balance payments. Existing attempt/session/amount checks and idempotent confirmation are preserved. Other signed TEST event types are acknowledged without processing payment.

## Local test forwarding

Stripe cannot deliver directly to localhost. The official Stripe CLI forwards those two TEST events to http://localhost:3041/api/payments/stripe/webhook.

A CLI listener has its own whsec_ secret. The local test server uses that listener secret as a process-only override. The registered dashboard endpoint secret remains in .env.local for Martin to copy to Vercel. Do not put the CLI listener secret in Vercel.

The listener and Next.js logs are kept privately under /tmp/tooltag-stripe-cli. Local Gmail/SMS/refund modes stay inactive. A Supabase service-role server key is required to verify the resulting TEST ledger entry; it is not exposed to the browser or committed. Only the two explicitly authorized Supabase connection variables may be exported for this test.

Use Stripe test card 4242 4242 4242 4242, a future expiry and any three-digit CVC. Only a TEST- job is used. A success redirect is not evidence of payment: the signed webhook must confirm the attempt, then repeated delivery must not produce an extra collection.

## Current verification status

The controlled 4242 payment succeeded on TEST-J-20261011-17 for $75.00 simulated USD. No live keys or real customer payments were used.

- Checkout: cs_test_a1PlTRNWpysQTbrnNO3e4DvXBOcZvO0vHjRVn8S40gBZujGvOF0WpRop7n
- PaymentIntent: pi_3UPWCECb87wF1fzi1717srYE
- Event: evt_1UPWCGCb87wF1fzi3ZFbhWJj
- Attempt: 64a3fa28-e91f-44c7-b963-8aa7d06a498d
- Collection: 62ce8050-0fc2-4333-a65c-a5bf6e0fa850
- Migration applied: 20261011232019_stripe_test_customer_access.sql

The CLI forwarded the completed event and the local webhook returned HTTP 200. Re-delivery of the identical signed event also returned 200 and left exactly one collection. Supabase confirms paid_confirmed, collected $75 and balance_due $0. The collection used the existing TEST sandbox account; the real payment account setting and its $168.96 ledger balance remained unchanged. Earlier rejected starts remain auditable as pending attempts without a Checkout reference; they did not create additional charges.

The account defaults to API 2026-09-30.endive, which removed payment_method_types. The adapter pins requests to supported API 2025-06-30.basil to preserve its existing card-only Checkout behavior. No account-wide API configuration was changed. Empty customer_email is omitted and Checkout locale is explicitly English.

Martin must configure the three TEST environment variables in Vercel and redeploy before deployed card payments can be used. The dashboard endpoint secret, rather than the local CLI listener secret, belongs in Vercel.

TEST confirmations use a private explicitly configured TEST account and TEST physical account; a missing/mismatched sandbox account fails closed. The real unit payment account setting is not modified. Existing confirmation matching, duplicate handling and non-TEST account selection remain intact.
