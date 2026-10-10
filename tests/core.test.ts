import { test } from "node:test";
import assert from "node:assert/strict";
import { cents, decimal, quoteTotal } from "../src/lib/domain/money";
import { email, evidenceName } from "../src/lib/integrations/contracts";
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
test("Email adapter never pretends a message succeeded", async () => {
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

import {simpleRouteTravel,straightLineKm,validPoint} from "../src/lib/domain/route-estimate";
import {geocodeAddress,refreshRouteEstimates} from "../src/lib/integrations/route-estimate";
test("Approximate route ETA uses ordered straight-line travel at 30 km/h plus fifteen minutes per remaining stop",async()=>{
 const a={latitude:0,longitude:0},b={latitude:0,longitude:0.135};
 assert.ok(Math.abs(straightLineKm(a,b)-15)<0.1);
 assert.equal(straightLineKm(a,a),0);
 assert.deepEqual(await simpleRouteTravel.minutes(a,[a,a,a]),[15,30,45]);
 const values=await simpleRouteTravel.minutes(a,[b,a]);
 assert.ok(values[0]>=45&&values[0]<=46);assert.ok(values[1]>=90&&values[1]<=91);
 assert.equal(validPoint({latitude:NaN,longitude:0}),false);
 assert.throws(()=>straightLineKm({latitude:91,longitude:0},a),/coordinates/);
});
test("Address coordinates reject ambiguous, missing and failed geocoder results",async()=>{
 const mock=(data:unknown)=> (async()=>new Response(JSON.stringify(data))) as typeof fetch;
 assert.deepEqual(await geocodeAddress("101 Test St",mock({result:{addressMatches:[{coordinates:{x:-111,y:40}}]}})),{latitude:40,longitude:-111});
 assert.equal(await geocodeAddress("101 Test St",mock({result:{addressMatches:[]}})),null);
 assert.equal(await geocodeAddress("101 Test St",mock({result:{addressMatches:[{},{}]}})),null);
 assert.equal(await geocodeAddress("101 Test St",(async()=>{throw Error("offline");}) as typeof fetch),null);
});

test("Missing intermediate coordinates make downstream ETA unavailable and travel providers remain replaceable",async()=>{
 const saved:{value:unknown}={value:null};
 const db={rpc:async(name:string,args?:{p_estimates?:unknown})=>{if(name==="driver_route_estimate_context")return {data:{closed:false,stops:[{id:"a",address:"",latitude:40,longitude:-111},{id:"b",address:"",latitude:null,longitude:null},{id:"c",address:"",latitude:40,longitude:-111}]},error:null};saved.value=args?.p_estimates;return {error:null};}};
 await refreshRouteEstimates(db as unknown as import("@supabase/supabase-js").SupabaseClient,"route",{latitude:40,longitude:-111},{minutes:async()=>[7]});
 assert.deepEqual((saved.value as {minutes:number|null}[]).map(e=>e.minutes),[7,null,null]);
});

import {StripeRouteRefundTransport} from '../src/lib/payments/route-refunds';
test('Automatic refunds are gated, use original Stripe payment and durable part keys, and do not call pending success',async()=>{
 let posts=0;let reused=false;
 const request=(async(url:unknown,init?:RequestInit)=>{
 const path=String(url);if(path.includes('checkout/sessions/'))return new Response(JSON.stringify({payment_intent:'pi_original',payment_status:'paid'}));
 if(init?.method==='POST'){posts++;assert.equal(new Headers(init.headers).get('Idempotency-Key'),'route-refund:comp:0.00');assert.equal(new URLSearchParams(String(init.body)).get('amount'),'500');assert.equal(new URLSearchParams(String(init.body)).get('payment_intent'),'pi_original');return new Response(JSON.stringify({id:'re_pending',status:'pending',amount:500,currency:'usd',payment_intent:'pi_original'}));}
 return new Response(JSON.stringify({data:reused?[{id:'re_pending',status:'succeeded',amount:500,currency:'usd',payment_intent:'pi_original',metadata:{route_part:'route-refund:comp:0.00'}}]:[],has_more:false}));
 }) as typeof fetch;
 const disabled=new StripeRouteRefundTransport(request,{STRIPE_SECRET_KEY:'sk_live_example',TOOLTAG_REFUND_MODE:'live',VERCEL_ENV:'preview'});
 assert.equal(disabled.configured(),false);await assert.rejects(disabled.refund({id:'comp',offset:0,amount:5,session:'cs_original'}),/not enabled/);assert.equal(posts,0);
 const enabled=new StripeRouteRefundTransport(request,{STRIPE_SECRET_KEY:'sk_test_example',TOOLTAG_REFUND_MODE:'test'});
 assert.equal((await enabled.refund({id:'comp',offset:0,amount:5,session:'cs_original'})).status,'pending');
 reused=true;assert.equal((await enabled.refund({id:'comp',offset:0,amount:5,session:'cs_original'})).status,'succeeded');assert.equal(posts,1);
});

import {driverDates} from "../src/lib/domain/driver-dates";
test("Driver route defaults use Sunday; configured delivery day changes only Return",()=>{
 assert.equal(driverDates("2026-10-11").return,"2026-10-11");
 assert.equal(driverDates("2026-10-11",new Date(),1).return,"2026-10-12");
 assert.equal(driverDates("2026-10-11",new Date(),1).pickup,"2026-10-17");
});
