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

test("Driver defaults choose the nearest of multiple configured route days",()=>{
 const dates=driverDates("2026-10-12",new Date(),[3,7],[2,6]);
 assert.equal(dates.pickup,"2026-10-13");assert.equal(dates.return,"2026-10-14");
 assert.equal(driverDates("2026-10-13",new Date(),[3,7],[2,6]).pickup,"2026-10-13");
});

import {routeProgress,jobTimelineProgress,spanishStopStatus} from "../src/lib/domain/customer-route-tracking";
test("Customer route timeline resolves failed stops without claiming delivery, and separates current/upcoming",()=>{
 const stops=[{position:1,status:"Completed",is_customer:false},{position:2,status:"Failed",is_customer:false},{position:3,status:"Arrived",is_customer:true},{position:4,status:"Requested",is_customer:false}];
 const result=routeProgress(stops);
 assert.equal(result.percentage,50);assert.equal(result.done.length,2);assert.equal(result.current[0].is_customer,true);assert.equal(result.upcoming[0].status,"Requested");
 assert.equal(spanishStopStatus.Failed,"Intento sin completar");assert.equal(routeProgress([]).percentage,0);
 assert.equal(routeProgress(stops.map(s=>({...s,status:"Completed"}))).percentage,100);
});
test("Completed job timeline has no upcoming stages and all stages are Done",()=>{
 const result=jobTimelineProgress(["In Process","Engraving","Completed"],"Completed");
 assert.equal(result.percentage,100);assert.equal(result.done.length,3);assert.deepEqual(result.upcoming,[]);
});


test("Payment proofs reject oversize and unsupported files before upload", async () => {
  const {paymentProofError, PAYMENT_PROOF_MAX_BYTES} = await import("../src/lib/payments/proof");
  assert.equal(paymentProofError({size: PAYMENT_PROOF_MAX_BYTES, type: "image/png"}), null);
  assert.ok(paymentProofError({size: PAYMENT_PROOF_MAX_BYTES + 1, type: "image/png"}));
  assert.ok(paymentProofError({size: 4.1 * 1024 * 1024, type: "image/jpeg"}));
  assert.ok(paymentProofError({size: 10, type: "application/pdf"}));
  assert.equal(paymentProofError({size: 100, type: "image/webp"}), null);
});

import { encryptSmsCredentials, decryptSmsCredentials, normalizeSmsPhone, resolveSmsConfig, smsNetworkAllowed, SnsSmsTransport, SmsFailure, renderSms } from "../src/lib/integrations/sms";
import { PublishCommand, CheckIfPhoneNumberIsOptedOutCommand } from "@aws-sdk/client-sns";
const smsTestCredentials = { accessKeyId: "TEST-NOT-AN-AWS-KEY", secretAccessKey: "TEST-NOT-A-SECRET" };
const smsTestConfig = { ...smsTestCredentials, region: "us-west-2", originationNumber: "+18015550101", testPhone: "+18015550102", enabled: true };
const smsTestEnv = { TOOLTAG_SMS_MODE: "live", VERCEL_ENV: "production" };
test("SMS credentials use authenticated encryption and never resolve incomplete configuration", () => {
  const env = { TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64") };
  const cipher = encryptSmsCredentials(smsTestCredentials, env);
  assert.ok(!cipher.includes(smsTestCredentials.secretAccessKey));
  assert.deepEqual(decryptSmsCredentials(cipher, env), smsTestCredentials);
  assert.notEqual(encryptSmsCredentials(smsTestCredentials, env), cipher);
  assert.throws(() => decryptSmsCredentials(cipher, { TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString("base64") }));
  assert.throws(() => encryptSmsCredentials(smsTestCredentials, {}));
  assert.equal(resolveSmsConfig({}, {}), null);
  assert.equal(resolveSmsConfig({}, { AWS_ACCESS_KEY_ID: "TEST" }), null);
  assert.equal(resolveSmsConfig({ region: "us-west-2", origination_number: "+18015550101" }, {}), null);
});
test("SMS local/test safety, phone normalization and test-recipient restriction", async () => {
  assert.equal(normalizeSmsPhone("(801) 555-0100"), "+18015550100");
  assert.equal(normalizeSmsPhone("+44 7700 900123"), "+447700900123");
  assert.equal(normalizeSmsPhone("8015550100junk"), null);
  assert.equal(normalizeSmsPhone("555"), null);
  assert.equal(smsNetworkAllowed({ TOOLTAG_SMS_MODE: "live", NODE_ENV: "production" }), false);
  assert.equal(smsNetworkAllowed({ ...smsTestEnv, TOOLTAG_SMS_MODE: "preview" }), false);
  let requests = 0; const mock = { async send() { requests++; return { isOptedOut: false, MessageId: "mock" }; } };
  await assert.rejects(new SnsSmsTransport(smsTestConfig, {}, mock).send("+18015550103", "test"), /SMS_NETWORK_DISABLED/);
  await assert.rejects(new SnsSmsTransport(smsTestConfig, { ...smsTestEnv, TOOLTAG_SMS_MODE: "test" }, mock).send("+18015550103", "test"), /SMS_MODE_BLOCKED/);
  await assert.rejects(new SnsSmsTransport(smsTestConfig, smsTestEnv, mock).send("+18015550103", "test", true), /SMS_MODE_BLOCKED/);
  assert.equal(requests, 0);
});
test("SNS checks provider opt-out, uses transactional origination and reports actual acceptance", async () => {
  const commands: (PublishCommand | CheckIfPhoneNumberIsOptedOutCommand)[] = [];
  const mock = { async send(command: PublishCommand | CheckIfPhoneNumberIsOptedOutCommand) { commands.push(command); return command instanceof PublishCommand ? { MessageId: "sns-test-id" } : { isOptedOut: false }; } };
  const id = await new SnsSmsTransport(smsTestConfig, smsTestEnv, mock).send("+18015550103", "ToolTag test");
  assert.equal(id, "sns-test-id"); assert.equal(commands.length, 2);
  assert.ok(commands[0] instanceof CheckIfPhoneNumberIsOptedOutCommand);
  const publish = commands[1] as PublishCommand;
  assert.equal(publish.input.MessageAttributes?.["AWS.MM.SMS.OriginationNumber"].StringValue, smsTestConfig.originationNumber);
  assert.equal(publish.input.MessageAttributes?.["AWS.SNS.SMS.SMSType"].StringValue, "Transactional");
  const optedOut = { async send() { return { isOptedOut: true }; } };
  await assert.rejects(new SnsSmsTransport(smsTestConfig, smsTestEnv, optedOut).send("+18015550103", "test"), /PROVIDER_OPT_OUT/);
});
test("SNS ambiguous failures are terminal Unknown; definitive rejects are Failed", async () => {
  for (const [error, expected] of [[new Error("timeout"), "Unknown"], [{ $metadata: { httpStatusCode: 403 } }, "Failed"]] as const) {
    const mock = { async send(command: PublishCommand | CheckIfPhoneNumberIsOptedOutCommand) { if (command instanceof PublishCommand) throw error; return { isOptedOut: false }; } };
    await assert.rejects(new SnsSmsTransport(smsTestConfig, smsTestEnv, mock).send("+18015550103", "test"), (failure: unknown) => failure instanceof SmsFailure && failure.status === expected);
  }
});
test("SMS templates preserve route/payment text, avoid foreign links and include opt-out", () => {
  const message = renderSms("RETURN_DRIVER_NEARBY", { text: "3 stops remaining. ETA approx. 40 minutes", action_path: "/status/test-token" }, "https://tooltag.example");
  assert.match(message, /3 stops remaining/); assert.match(message, /ETA approx/); assert.match(message, /https:\/\/tooltag.example\/status\/test-token/); assert.match(message, /Reply STOP/);
  assert.ok(!renderSms("PAYMENT_DUE", { text: "Pay before 1 PM", action_path: "https://evil.example" }, "https://tooltag.example").includes("evil"));
  assert.match(renderSms("Agreement accepted copy", {}, "https://tooltag.example"), /accepted/);
  assert.throws(() => renderSms("unrecognized", {}, "https://tooltag.example"));
  assert.throws(() => renderSms("PAYMENT_DUE", { text: "test" }, "http://tooltag.example"));
});
