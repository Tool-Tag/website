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
    assert.equal((requestInit?.headers as Record<string,string>)["Stripe-Version"],"2025-06-30.basil");
    const body = new URLSearchParams(String(requestInit?.body));
    assert.equal(body.get("line_items[0][price_data][unit_amount]"), "1999");
    assert.equal(body.get("metadata[attempt_id]"), paymentInput.attemptId);
    assert.equal(body.get("metadata[payment_scope]"), "fee_only");
    await stripe.start({...paymentInput,customerEmail:""});
    assert.equal(new URLSearchParams(String(requestInit?.body)).has("customer_email"),false);

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
test("SMS alerts use one short English format and retain full trusted links", () => {
 const payload={job_code:"TT-J-2026-00123",stage:"Engraving",action_path:"/status/test-token"};
 const message=renderSms("JOB_STATUS_UPDATE",payload,"https://tooltag.martinlab.studio");
 assert.equal(message,"ToolTag: Your order TT-J-2026-00123 moved to Engraving. Details: https://tooltag.martinlab.studio/status/test-token");
 assert.ok(message.length<=160);
 for(const [event,stage] of [["RETURN_DRIVER_NEARBY","3 Stops Away"],["PICKUP_ARRIVED","Driver Arrived"],["PAYMENT_DUE","Payment Due"],["JOB_CONFIRMED","Confirmed"]]) {
  assert.ok(renderSms(event,payload,"https://tooltag.example").includes("moved to "+stage+"."));
 }
 const longPath="/status/"+"a".repeat(72);
 assert.ok(renderSms("PAYMENT_DUE",{...payload,action_path:longPath},"https://tooltag.martinlab.studio").endsWith(longPath));
 assert.throws(()=>renderSms("PAYMENT_DUE",{...payload,action_path:"https://evil.example"},"https://tooltag.example"));
 assert.throws(()=>renderSms("PAYMENT_DUE",payload,"http://tooltag.example"));
 assert.throws(()=>renderSms("unknown",payload,"https://tooltag.example"));
 assert.match(renderSms("QUOTE_SENT",{job_code:"TT-Q-2026-00123",action_path:"/review/quote-token"},"https://tooltag.example"),/TT-Q-2026-00123 moved to Quote Ready/);
});

test("Phone verification is strictly opt-in and disabled registration needs no proof", async () => {
 const {phoneVerificationEnabled,verifiedPhone,verificationSession}=await import("../src/lib/integrations/phone-verification");
 assert.equal(phoneVerificationEnabled({}),false);assert.equal(phoneVerificationEnabled({PHONE_VERIFICATION_ENABLED:"false"}),false);assert.equal(phoneVerificationEnabled({PHONE_VERIFICATION_ENABLED:"true"}),true);
 assert.equal(await verifiedPhone("not-a-phone"),true);
 assert.equal(verificationSession("forged"),null);
});

test("Verification SMS needs its own enabled flag and respects test recipient restrictions", async () => {
 const mock={async send(command:PublishCommand|CheckIfPhoneNumberIsOptedOutCommand){return command instanceof PublishCommand?{MessageId:"verification-code"}:{isOptedOut:false};}};
 const config={...smsTestConfig,enabled:false};
 await assert.rejects(new SnsSmsTransport(config,smsTestEnv,mock).send("+18015550103","Code 123456",false,true),/SMS_MODE_BLOCKED/);
 assert.equal(await new SnsSmsTransport(config,{...smsTestEnv,PHONE_VERIFICATION_ENABLED:"true"},mock).send("+18015550103","Code 123456",false,true),"verification-code");
 await assert.rejects(new SnsSmsTransport(config,{...smsTestEnv,PHONE_VERIFICATION_ENABLED:"true",TOOLTAG_SMS_MODE:"test"},mock).send("+18015550103","Code 123456",true,true),/SMS_MODE_BLOCKED/);
});

test("Stripe configuration rejects live, swapped and mismatched key prefixes", async () => {
 const {stripeConfigured,stripeTestEvent}=await import("../src/lib/payments/stripe");
 const names=["STRIPE_SECRET_KEY","STRIPE_WEBHOOK_SECRET","NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY"] as const;
 const before=Object.fromEntries(names.map(n=>[n,process.env[n]]));
 try {
  process.env.STRIPE_SECRET_KEY="sk_test_example";process.env.STRIPE_WEBHOOK_SECRET="whsec_example";process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY="pk_test_example";
  assert.equal(stripeConfigured(),true);
  process.env.STRIPE_SECRET_KEY="pk_test_example";assert.equal(stripeConfigured(),false);
  process.env.STRIPE_SECRET_KEY="sk_live_example";assert.equal(stripeConfigured(),false);
  process.env.STRIPE_SECRET_KEY="sk_test_example";process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY="sk_test_example";assert.equal(stripeConfigured(),false);
  assert.equal(stripeTestEvent({id:"evt_test",type:"checkout.session.completed",livemode:false,data:{object:{id:"cs_test_example"}}}),true);
  assert.equal(stripeTestEvent({id:"evt_wrong_mode",type:"checkout.session.completed",livemode:true,data:{object:{id:"cs_wrong_mode"}}}),false);
 }finally{for(const n of names){if(before[n]===undefined)delete process.env[n];else process.env[n]=before[n];}}
});

import { can, canAny, canMutate, driverOnly, EMPLOYEE_BLOCKS, PERMISSION_BLOCKS, sectionPermissions } from "../src/lib/auth/permissions";
test("RBAC uses role unions, future Owner permissions, and fail-closed action defaults", () => {
  const owner = { owner: true, blocks: [] };
  const employee = { owner: false, blocks: EMPLOYEE_BLOCKS };
  const driver = { owner: false, blocks: ["driver.routes"] };
  assert.equal(new Set(PERMISSION_BLOCKS.map(b => b[0])).size, PERMISSION_BLOCKS.length);
  assert.equal(can(owner, "future.block"), true);
  assert.equal(can(employee, "quotes.view"), true);
  assert.equal(canMutate(employee, "quote"), false);
  assert.equal(canMutate(employee, "confirm-payment"), true);
  assert.equal(canMutate(employee, "cancellation-refund"), false);
  assert.equal(canMutate(employee, "unknown-operation"), false);
  assert.equal(canMutate({owner:false,blocks:["settings.manage"]}, "settings"), false);
  assert.equal(canMutate(driver, "route-cash"), true);
  assert.equal(canMutate(driver, "confirm-payment"), false);
  assert.equal(driverOnly(driver), true);
  assert.equal(driverOnly({ owner: false, blocks: [...driver.blocks, "jobs.view"] }), false);
  assert.equal(driverOnly(owner), false);
  assert.equal(canAny(driver, sectionPermissions("finance")), false);
  assert.equal(canAny(employee, sectionPermissions("settings")), false);
  assert.equal(can({ owner: false, blocks: ["quotes.view", "quotes.manage"] }, "quotes.manage"), true);
});

import { SupportGmail, parseSupportMessage, supportEnabled, supportMime, type SupportReply } from "../src/lib/integrations/support-gmail";
const supportTestEnv={NODE_ENV:"production",VERCEL_ENV:"production",TOOLTAG_SUPPORT_INBOX_ENABLED:"true",GOOGLE_CLIENT_ID:"fixture",GOOGLE_CLIENT_SECRET:"fixture",GOOGLE_REFRESH_TOKEN:"fixture",TOOLTAG_MAIL_MODE:"test-delivery",TOOLTAG_MAIL_TEST_RECIPIENT:"customer@example.test"};
const supportReply:SupportReply={id:"90000000-0000-0000-0000-000000000095",mailbox:"support",to:"customer@example.test",subject:"[TT-C-2026-00001] Re: Tools",body:"Hello\n\nMartin\nToolTag",message_id:"",thread_id:"thread-1",in_reply_to:"<incoming@example.test>",references:"<older@example.test> <incoming@example.test>"};
test("Support parser only imports Support/Hello incoming mail and renders HTML as inert text",()=>{
 const incoming={id:"in",threadId:"thread",internalDate:String(Date.now()),payload:{mimeType:"text/html",headers:[{name:"To",value:"ToolTag <support@tooltag.martinlab.studio>"},{name:"From",value:"Customer <customer@example.test>"},{name:"Message-ID",value:"<incoming@example.test>"}],body:{data:Buffer.from('<script>alert(1)</script><p>Hello &amp; welcome</p>').toString("base64url")}}};
 const parsed=parseSupportMessage(incoming);assert.equal(parsed?.mailbox,"support");assert.equal(parsed?.sender_email,"customer@example.test");assert.ok(!parsed?.body.includes("alert"));assert.match(parsed!.body,/Hello & welcome/);
 assert.equal(parseSupportMessage({...incoming,labelIds:["SENT"]}),null);
 assert.equal(parseSupportMessage({...incoming,payload:{...incoming.payload,headers:[{name:"To",value:"quotes@tooltag.martinlab.studio"},{name:"From",value:"customer@example.test"}]}}),null);
 assert.equal(parseSupportMessage({...incoming,payload:{...incoming.payload,headers:[{name:"To",value:"billing@tooltag.martinlab.studio"},{name:"From",value:"customer@example.test"}]}}),null);
 assert.equal(supportEnabled({...supportTestEnv,NODE_ENV:"development"}),false);assert.equal(supportEnabled({...supportTestEnv,VERCEL_ENV:"preview"}),false);assert.equal(supportEnabled({}),false);
});
test("Support MIME routes From/Reply-To, preserves reply headers and signs with user name",()=>{
 const mime=supportMime(supportReply);assert.match(mime,/From: .*<support@tooltag.martinlab.studio>/);assert.match(mime,/Reply-To: support@tooltag.martinlab.studio/);assert.match(mime,/In-Reply-To: <incoming@example.test>/);assert.match(mime,/References: <older@example.test> <incoming@example.test>/);assert.match(mime,/Message-ID: <90000000-0000-0000-0000-000000000095@tooltag.martinlab.studio>/);
 assert.match(supportMime({...supportReply,mailbox:"hello"}),/Reply-To: hello@tooltag.martinlab.studio/);
 assert.throws(()=>supportMime({...supportReply,to:"victim@example.test\r\nBcc: attacker@example.test"}));
});
test("Support Gmail honors test recipient and uses OAuth/raw/threadId; failure does not pretend delivery",async()=>{
 const calls:{url:string;init?:RequestInit}[]=[];
 const request:typeof fetch=async(url,init)=>{calls.push({url:String(url),init});return new Response(JSON.stringify(String(url).includes("oauth2") ? {access_token:"fixture-token"}:{id:"sent-1",threadId:"thread-new"}),{status:200});};
 const gmail=new SupportGmail(supportTestEnv,request);assert.deepEqual(await gmail.send(supportReply),{id:"sent-1",threadId:"thread-new"});
 const payload=JSON.parse(String(calls[1].init?.body));assert.equal(payload.threadId,"thread-1");assert.match(Buffer.from(payload.raw,"base64url").toString(),/In-Reply-To:/);
 await assert.rejects(gmail.send({...supportReply,to:"real-customer@example.test"}),/MAIL_TEST_RECIPIENT_REQUIRED/);assert.equal(calls.length,2);
 const failing:typeof fetch=async(url)=>String(url).includes("oauth2") ? new Response(JSON.stringify({access_token:"fixture-token"})):Promise.reject(Error("timeout"));
 await assert.rejects(new SupportGmail(supportTestEnv,failing).send(supportReply),/GMAIL_DELIVERY_UNKNOWN/);
 const forbidden:typeof fetch=async(url)=>String(url).includes("oauth2") ? new Response(JSON.stringify({access_token:"fixture-token"})):new Response("denied",{status:403});
 await assert.rejects(new SupportGmail(supportTestEnv,forbidden).list(new Date().toISOString()),/GMAIL_REJECTED_403/);
});
test("Support subject mismatch retries only a definite 400, never an ambiguous send",async()=>{
 const bodies:string[]=[];
 const request:typeof fetch=async(url,init)=>{
  if(String(url).includes("oauth2"))return new Response(JSON.stringify({access_token:"fixture-token"}));
  bodies.push(String(init?.body));return bodies.length===1 ? new Response("bad thread",{status:400}):new Response(JSON.stringify({id:"sent-new",threadId:"new-thread"}));
 };
 const sent=await new SupportGmail(supportTestEnv,request).send(supportReply);assert.equal(sent.threadId,"new-thread");assert.equal(JSON.parse(bodies[0]).threadId,"thread-1");assert.equal(JSON.parse(bodies[1]).threadId,undefined);assert.equal(JSON.parse(bodies[0]).raw,JSON.parse(bodies[1]).raw);
 let attempts=0;const ambiguous:typeof fetch=async(url)=>String(url).includes("oauth2") ? new Response(JSON.stringify({access_token:"fixture-token"})):(attempts++,new Response("server error",{status:503}));
 await assert.rejects(new SupportGmail(supportTestEnv,ambiguous).send(supportReply),/GMAIL_DELIVERY_UNKNOWN/);assert.equal(attempts,1);
 assert.throws(()=>parseSupportMessage({id:"x",threadId:"x",internalDate:String(Date.now())},{TOOLTAG_INBOX_SUPPORT_ADDRESS:"quotes@tooltag.martinlab.studio"}),/SUPPORT_ALIAS_INVALID/);
});

import { smsPolicyLinks } from "../src/lib/domain/sms-consent";
import { emptyGetTaggedRequest, getTaggedRequestSchema } from "../src/lib/public/get-tagged";
test("SMS policy links require approved HTTPS URLs and intake consent defaults to unchecked",()=>{
 assert.equal(smsPolicyLinks({}),null);assert.equal(smsPolicyLinks({privacy:"javascript:alert(1)",terms:"https://tooltag.example/terms"}),null);
 assert.equal(smsPolicyLinks({privacy:"http://tooltag.example/privacy",terms:"https://tooltag.example/terms"}),null);
 assert.deepEqual(smsPolicyLinks({privacy:"https://tooltag.example/privacy",terms:"https://tooltag.example/terms"}),{privacy:"https://tooltag.example/privacy",terms:"https://tooltag.example/terms"});
 const request=emptyGetTaggedRequest();Object.assign(request.contact,{name:"TEST",email:"test@example.test",phone:"3852142163"});Object.assign(request.items[0],{article:"Battery",brand:"Dewalt"});Object.assign(request.items[0].marks[0],{text:"TEST",location:"Left"});
 const {sms_opt_in,sms_phone,...legacy}=request;assert.equal(sms_opt_in,false);assert.equal(sms_phone,"");assert.equal(getTaggedRequestSchema.parse(legacy).sms_opt_in,false);
 assert.equal(getTaggedRequestSchema.parse({...request,sms_opt_in:true,sms_phone:"+13852142163"}).sms_opt_in,true);
});
