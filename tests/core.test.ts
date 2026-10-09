import { test } from "node:test";
import assert from "node:assert/strict";
import { cents, decimal, quoteTotal } from "../src/lib/domain/money";
import { drive, email, evidenceName } from "../src/lib/integrations/contracts";
test("Money calculations use integer cents, including fractional unit prices", () => {
  assert.equal(
    quoteTotal([
      { quantity: 3, unit_price: "0.10" },
      { quantity: 1, unit_price: "0.20" },
    ]),
    "0.50",
  );
  assert.equal(decimal(cents("999999999999.99")), "999999999999.99");
  for (const invalid of ["1.001", "-1", "NaN", "1e2", ""])
    assert.throws(() => cents(invalid));
});
test("Adapters never pretend an upload or message succeeded", async () => {
  await assert.rejects(
    () => drive.upload("root", "receipt", new Uint8Array(), "image/jpeg"),
    /not connected/,
  );
  await assert.rejects(
    () =>
      email.send({
        recipient: "test@example.test",
        subject: "Test",
        body: "Test",
        idempotencyKey: "test",
      }),
    /not connected/,
  );
  assert.equal(
    evidenceName("TT-J-2026-00124", "Receiving", 2),
    "TT-J-2026-00124-Receiving-02.jpg",
  );
});

import { loginFailure } from "../src/lib/domain/auth-errors";
test("Login errors distinguish configuration from credentials without leaking raw messages", () => {
  assert.equal(
    loginFailure({ message: "Invalid API key" }).reference,
    "AUTH_CONFIG",
  );
  assert.equal(
    loginFailure({ code: "invalid_credentials", status: 400 }).reference,
    "invalid_credentials",
  );
  assert.equal(
    loginFailure({ code: "email_not_confirmed" }).reference,
    "email_not_confirmed",
  );
  assert.equal(loginFailure({ status: 429 }).reference, "AUTH_RATE_LIMIT");
  const unknown = loginFailure({
    message: "private token and internal details",
  });
  assert.equal(unknown.reference, "AUTH_UNAVAILABLE");
  assert.ok(!unknown.message.includes("private token"));
});

import { blankItem, withAdaptation } from "../src/lib/domain/quote-items";
test("Logo adaptation charges once per distinct link, across quantities and articles", () => {
  const a = {
    ...blankItem(),
    quantity: 10,
    unit_price: "2.00",
    marks: [
      {
        type: "Image / Logo" as const,
        text: "",
        url: "https://example.com/a.png",
      },
    ],
  };
  const b = { ...a, quantity: 2 };
  assert.equal(quoteTotal(withAdaptation([a, b])), "27.00");
  const c = {
    ...a,
    quantity: 1,
    marks: [
      ...a.marks,
      {
        type: "Image / Logo" as const,
        text: "",
        url: "https://example.com/b.png",
      },
    ],
  };
  assert.equal(quoteTotal(withAdaptation([a, b, c])), "37.00");
  assert.equal(
    quoteTotal(withAdaptation([{ ...blankItem(), unit_price: "2.00" }])),
    "2.00",
  );
});

test("Paint charges $2 per colored piece, not per engraving, and excludes manual fees", () => {
  const colored = {...blankItem(), quantity: 3, unit_price: "10.00", marks: [{type: "Text" as const, text: "A", url: "", paint_fill: true}, {type: "Text" as const, text: "B", url: "", paint_fill: true}]};
  assert.equal(quoteTotal(withAdaptation([colored])), "51.00");
  assert.equal(quoteTotal(withAdaptation([{...colored, marks: colored.marks.map(m => ({...m, paint_fill: false}))}])), "45.00");
  assert.equal(quoteTotal(withAdaptation([{...colored, engraving_type: "Fee"}])), "30.00");
});


import {
  LOGISTICS_OPTIONS,
  logisticsFee,
  logisticsRequiresDelivery,
  logisticsRequiresPickup,
} from "../src/lib/domain/logistics";
import { ManualPaymentProvider } from "../src/lib/payments/manual";
import {
  StripePaymentProvider,
  verifyStripeSignature,
} from "../src/lib/payments/stripe";
import { createHmac } from "node:crypto";

test("Logistics options keep the four approved names, prices and TT legs", () => {
  assert.deepEqual(
    LOGISTICS_OPTIONS.map((option) => [
      option.name,
      option.fee,
      option.pickup,
      option.delivery,
    ]),
    [
      ["Pickup Only", 9.99, true, false],
      ["Pickup & Delivery", 19.99, true, true],
      ["Drop-off & Pickup", 0, false, false],
      ["Drop-off + Delivery", 9.99, false, true],
    ],
  );
  assert.equal(logisticsFee("pickup_delivery"), 19.99);
  assert.equal(logisticsRequiresPickup("dropoff_delivery"), false);
  assert.equal(logisticsRequiresDelivery("dropoff_delivery"), true);
});

const paymentInput = {
  attemptId: "10000000-0000-0000-0000-000000000099",
  amountCents: 1999,
  currency: "usd" as const,
  description: "ToolTag logistics fee · TT-J-2026-00099",
  customerEmail: "customer@example.test",
  successUrl: "https://tooltag.example.test/success",
  cancelUrl: "https://tooltag.example.test/cancel",
  jobId: "20000000-0000-0000-0000-000000000099",
  quoteId: "30000000-0000-0000-0000-000000000099",
  paymentScope: "fee_only" as const,
};

test("Manual payment provider is configuration-gated and never self-confirms", async () => {
  const missing = new ManualPaymentProvider("Zelle", "");
  assert.equal(missing.isConfigured(), false);
  await assert.rejects(() => missing.start(paymentInput), /not configured/);

  const ready = new ManualPaymentProvider("Venmo", "@tooltag-test");
  assert.equal(ready.isConfigured(), true);
  assert.deepEqual(await ready.start(paymentInput), {
    provider: "manual",
    state: "pending_verification",
  });
});

test("Stripe adapter creates hosted Checkout in pending state and uses idempotency", async () => {
  const previousSecret = process.env.STRIPE_SECRET_KEY;
  const previousWebhook = process.env.STRIPE_WEBHOOK_SECRET;
  process.env.STRIPE_SECRET_KEY = "sk_test_tooltag_placeholder";
  process.env.STRIPE_WEBHOOK_SECRET = "whsec_tooltag_placeholder";

  let requestUrl = "";
  let requestInit: RequestInit | undefined;
  const fakeFetch: typeof fetch = async (input, init) => {
    requestUrl = String(input);
    requestInit = init;
    return new Response(
      JSON.stringify({
        id: "cs_test_123",
        url: "https://checkout.stripe.test/session",
        payment_status: "unpaid",
      }),
      {
        status: 200,
        headers: { "content-type": "application/json" },
      },
    );
  };

  try {
    const stripe = new StripePaymentProvider(fakeFetch);
    assert.equal(stripe.isConfigured(), true);
    const result = await stripe.start(paymentInput);
    assert.equal(result.state, "pending");
    assert.equal(result.providerReference, "cs_test_123");
    assert.equal(result.redirectUrl, "https://checkout.stripe.test/session");
    assert.match(requestUrl, /checkout\/sessions$/);
    assert.equal(
      (requestInit?.headers as Record<string, string>)["Idempotency-Key"],
      paymentInput.attemptId,
    );
    const body = new URLSearchParams(String(requestInit?.body));
    assert.equal(body.get("line_items[0][price_data][unit_amount]"), "1999");
    assert.equal(body.get("metadata[attempt_id]"), paymentInput.attemptId);
    assert.equal(body.get("metadata[payment_scope]"), "fee_only");
  } finally {
    if (previousSecret === undefined) delete process.env.STRIPE_SECRET_KEY;
    else process.env.STRIPE_SECRET_KEY = previousSecret;
    if (previousWebhook === undefined) delete process.env.STRIPE_WEBHOOK_SECRET;
    else process.env.STRIPE_WEBHOOK_SECRET = previousWebhook;
  }
});

test("Stripe webhook verification rejects tampered or stale payloads", () => {
  const secret = "whsec_test_secret";
  const body = JSON.stringify({ id: "evt_test", type: "checkout.session.completed" });
  const timestamp = 1_800_000_000;
  const signature = createHmac("sha256", secret)
    .update(`${timestamp}.${body}`)
    .digest("hex");
  const header = `t=${timestamp},v1=${signature}`;

  assert.equal(
    verifyStripeSignature(body, header, secret, timestamp + 30),
    true,
  );
  assert.equal(
    verifyStripeSignature(body + "x", header, secret, timestamp + 30),
    false,
  );
  assert.equal(
    verifyStripeSignature(body, header, secret, timestamp + 600),
    false,
  );
});
