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

import {routeProgress,jobTimelineProgress,stopStatusLabel} from "../src/lib/domain/customer-route-tracking";
test("Customer route timeline resolves failed stops without claiming delivery, and separates current/upcoming",()=>{
 const stops=[{position:1,status:"Completed",is_customer:false},{position:2,status:"Failed",is_customer:false},{position:3,status:"Arrived",is_customer:true},{position:4,status:"Requested",is_customer:false}];
 const result=routeProgress(stops);
 assert.equal(result.percentage,50);assert.equal(result.done.length,2);assert.equal(result.current[0].is_customer,true);assert.equal(result.upcoming[0].status,"Requested");
 assert.equal(stopStatusLabel.Failed,"Attempt not completed");assert.equal(routeProgress([]).percentage,0);
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

 test("Get Tagged allows no phone or consent and welcome SMS includes STOP",()=>{
 const request=emptyGetTaggedRequest();Object.assign(request.contact,{name:"TEST Optional",email:"optional@example.test",phone:""});Object.assign(request.items[0],{article:"Battery",brand:"Dewalt"});Object.assign(request.items[0].marks[0],{text:"TEST",location:"Left"});
 const parsed=getTaggedRequestSchema.parse(request);assert.equal(parsed.contact.phone,"");assert.equal(parsed.sms_opt_in,false);assert.equal(parsed.sms_policy_accepted,false);
 assert.match(renderSms("SMS_WELCOME",{},"https://tooltag.example"),/^ToolTag: Welcome!.*HELP.*STOP/);
 });

import {salesTax} from "../src/lib/domain/sales-tax";
test("Sales tax uses exact cents, includes fees and rounds half-up",()=>{
 assert.deepEqual(salesTax("59.99","7.45"),{subtotal:"59.99",tax_rate:"7.45",tax_amount:"4.47",total:"64.46"});
 assert.equal(salesTax("19.99","7.45").total,"21.48");assert.equal(salesTax("0.10","5").tax_amount,"0.01");
 assert.equal(salesTax("100.00","0").total,"100.00");assert.equal(salesTax("100.00","8.125").total,"108.13");
 assert.throws(()=>salesTax("100.00","101"));assert.throws(()=>salesTax("100.00","7.4511"));
});

import {venmoPaymentUrl,PAYMENT_PAYEE_DISCLAIMER} from "../src/lib/payments/venmo";
test("Venmo payee link uses the configured handle and cannot escape its origin",()=>{
 assert.equal(venmoPaymentUrl("@boftbuild"),"https://venmo.com/boftbuild");
 assert.equal(venmoPaymentUrl("boftbuild"),"https://venmo.com/boftbuild");
 assert.equal(venmoPaymentUrl("https://evil.example"),null);assert.equal(venmoPaymentUrl("boftbuild?redirect=evil"),null);
 assert.match(PAYMENT_PAYEE_DISCLAIMER,/Bandits of the Framing LLC.*payment memo/);
});

import {processRouteRefunds} from '../src/lib/payments/route-refunds';
test('Refund worker is inert regardless of configured provider keys',async()=>{
 assert.deepEqual(await processRouteRefunds(),{enabled:false,processed:0});
});

import {urgency,attentionBands} from "../src/lib/domain/urgent-attention";
test("Urgency combines categories, preserves overdue records and always puts Lost in red",()=>{
 assert.deepEqual([1,2,3,4,5,7,8].map(d=>urgency("refund",d)),["green","green","orange","orange","red","red","red"]);
 assert.deepEqual([1,2,3,4,5,6].map(d=>urgency("problem",d)),["green","orange","orange","red","red","red"]);
 assert.equal(urgency("lost",0),"red");
 const bands=attentionBands(["refund","problem","lost"].map((kind,i)=>({kind:kind as "refund"|"problem"|"lost",id:String(i),label:"test",href:"/app",days:5,urgency:urgency(kind as "refund"|"problem"|"lost",5)})));
 assert.equal(bands[0].items.length,3);
});

import {queueDays,classifyAttention} from "../src/lib/domain/urgent-attention";
test("Refund calendar days and response weekdays use Denver inclusive day 1 across weekends/DST",()=>{
 assert.equal(queueDays("2026-10-09T18:00:00Z",new Date("2026-10-12T18:00:00Z")),4);
 assert.equal(queueDays("2026-10-09T18:00:00Z",new Date("2026-10-12T18:00:00Z"),true),2);
 assert.equal(queueDays("2026-10-10T00:01:00Z",new Date("2026-10-10T01:00:00Z")),1);
 assert.equal(queueDays("2026-10-31T18:00:00Z",new Date("2026-11-02T18:00:00Z")),3);
});

test("Refund urgency uses confirmed business days and weekend submissions start counting on Monday",()=>{
 assert.equal(queueDays("2026-10-11T18:00:00Z",new Date("2026-10-12T18:00:00Z"),true),1);
 const item=classifyAttention([{kind:"refund",id:"1",label:"test",href:"/app/refunds",started_at:"2026-10-09T18:00:00Z"}],new Date("2026-10-12T18:00:00Z"))[0];
 assert.equal(item.days,2);assert.equal(item.urgency,"green");
});

import {aggregateBands,categoryBadge} from "../src/lib/domain/urgent-attention";
test("Popup aggregates categories without individual records and menu urgency uses red over orange over green",()=>{
 const items=classifyAttention([
 {kind:"refund",id:"r1",label:"one",href:"/app/refunds",started_at:"2026-10-13T18:00:00Z"},
 {kind:"refund",id:"r2",label:"two",href:"/app/refunds",started_at:"2026-10-09T18:00:00Z"},
 {kind:"refund",id:"r3",label:"three",href:"/app/refunds",started_at:"2026-10-02T18:00:00Z"},
 {kind:"problem",id:"p",label:"support",href:"/app/notifications",started_at:"2026-10-09T18:00:00Z"},
 {kind:"lost",id:"l",label:"lost",href:"/app/lost",started_at:"2026-10-14T18:00:00Z"}],new Date("2026-10-14T18:00:00Z"));
 assert.deepEqual(categoryBadge(items,"refund"),{count:3,color:"red"});
 assert.equal(categoryBadge(items.filter(i=>i.id!=="r3"),"refund").color,"orange");
 assert.deepEqual(categoryBadge([],"refund"),{count:0,color:"green"});
 const bands=aggregateBands(items);assert.equal(bands.length,3);assert.equal(bands[0].count,3);
 assert.equal(bands[0].categories.length,3);assert.ok(bands.every(b=>b.categories.every(c=>!('id' in c))));
});

import {supportAckEnabled} from "../src/lib/integrations/support-gmail";
test("Automatic receipts require production live mail and never dispatch in local, preview or test-delivery mode",()=>{
 const env={TOOLTAG_SUPPORT_INBOX_ENABLED:"true",TOOLTAG_MAIL_MODE:"live",NODE_ENV:"production",VERCEL_ENV:"production",GOOGLE_CLIENT_ID:"fixture",GOOGLE_CLIENT_SECRET:"fixture",GOOGLE_REFRESH_TOKEN:"fixture"};
 assert.equal(supportAckEnabled(env),true);
 assert.equal(supportAckEnabled({...env,TOOLTAG_MAIL_MODE:"test-delivery"}),false);
 assert.equal(supportAckEnabled({...env,NODE_ENV:"development",TOOLTAG_MAIL_ALLOW_LOCAL_SEND:"true"}),false);
 assert.equal(supportAckEnabled({...env,VERCEL_ENV:"preview"}),false);
});

import {refundAttention,compareRefundUrgency,refundEligibility,refundCompletionLabel} from "../src/lib/domain/refund-flow";
import {renderNotification} from "../src/lib/integrations/notification-mail";
test('Refund list uses confirmed business days, red-first sorting and preserves overdue red',()=>{
 const now=new Date('2026-10-14T18:00:00Z');
 assert.deepEqual(refundAttention(null,now),{days:0,color:'green'});
 assert.deepEqual(refundAttention('2026-10-13T18:00:00Z',now),{days:2,color:'green'});
 assert.deepEqual(refundAttention('2026-10-09T18:00:00Z',now),{days:4,color:'orange'});
 assert.deepEqual(refundAttention('2026-10-08T18:00:00Z',now),{days:5,color:'red'});
 assert.equal(refundAttention('2026-09-28T18:00:00Z',now).color,'red');
 const rows=[null,'2026-10-09T18:00:00Z','2026-10-08T18:00:00Z'].map(confirmed_at=>({confirmed_at,requested_at:'2026-10-01T18:00:00Z'}));
 assert.deepEqual(rows.sort((a,b)=>compareRefundUrgency(a,b,now)).map(r=>r.confirmed_at),['2026-10-08T18:00:00Z','2026-10-09T18:00:00Z',null]);
 assert.equal(refundEligibility('2026-10-01T18:00:00Z','2026-10-15T18:00:00Z'),'Within the 14-calendar-day reporting window');
 assert.equal(refundEligibility('2026-10-01T18:00:00Z','2026-10-16T18:00:00Z'),'Outside the 14-calendar-day reporting window');
 assert.equal(refundEligibility(null,'2026-10-16T18:00:00Z'),'Needs origin event/date review');
 assert.equal(refundCompletionLabel('No response within 5 days'),'Auto-completed, no response');
 assert.match(refundCompletionLabel('Staff confirmed receipt','Email'),/Client confirmed.*Email/);
});
test('Refund issued mail shows secure proof and Confirm Receipt without signed storage URLs',()=>{
 const link='https://tooltag.martinlab.studio/refund/'+'a'.repeat(64);
 const message=renderNotification('Refund issued','Your refund was issued.','test@example.test','REFUND_UPDATE',link,'Confirm Receipt',link+'/proof');
 assert.match(message.html,/Confirm Receipt/);assert.match(message.html,/View refund screenshot/);
 assert.ok(message.text.includes(link+'/proof'));assert.doesNotMatch(message.html,/supabase.co|object\/sign/);
 assert.throws(()=>renderNotification('Refund','Issued','test@example.test','REFUND_UPDATE',link,'Confirm Receipt','http://unsafe.example.test/proof'),/Secure proof/);
});


import {validateRefundIssueAmount,refundAmountRemaining} from "../src/lib/domain/refund-flow";
test("Manual refund execution must record the approved unissued amount in exact cents",()=>{
 assert.equal(validateRefundIssueAmount("9.99","19.99","10.00"),null);
 assert.equal(validateRefundIssueAmount("10","10.00","0"),null);
 assert.equal(refundAmountRemaining("0.30","0.10"),"0.20");
 assert.match(validateRefundIssueAmount("10.00","19.99","10.00")!,/approved refund/);
 assert.match(validateRefundIssueAmount("5.00","10.00","0")!,/approved refund/);
 assert.match(validateRefundIssueAmount("0","10.00","10.00")!,/approved refund/);
 for(const value of ["","-1","1e1","9.999","NaN"])assert.match(validateRefundIssueAmount(value,"10","0")!,/valid refund amount/);
});


import {shopBoardLeg} from "../src/lib/domain/shop-board-data";
test("Shop board defaults to a leg the staff member is permitted to operate",()=>{
 assert.deepEqual(shopBoardLeg({owner:false,blocks:['pr.returns']}),{pickup:false,delivery:true,leg:'Return'});
 assert.deepEqual(shopBoardLeg({owner:false,blocks:['pr.receiving']},'Delivery'),{pickup:true,delivery:false,leg:'Pickup'});
 assert.equal(shopBoardLeg({owner:true,blocks:[]},'Delivery').leg,'Return');
});

import {lostCanFinalize} from "../src/lib/domain/lost-flow";
test("Lost finalization requires approval plus completed replacement/refund, never just a customer choice",()=>{
 assert.equal(lostCanFinalize({status:"In Process",customer_choice:"Replace Item",approved_at:null}),false);
 assert.equal(lostCanFinalize({status:"In Process",customer_choice:"Replace Item",approved_at:"2026-10-17",replacement_at_shop_at:"2026-10-17",replacement_expense_id:"expense-id"}),true);
 assert.equal(lostCanFinalize({status:"In Process",customer_choice:"Refund money",approved_at:"2026-10-17",refund_status:"Issued"}),false);
 assert.equal(lostCanFinalize({status:"In Process",customer_choice:"Refund money",approved_at:"2026-10-17",refund_status:"Completed"}),true);
 assert.equal(lostCanFinalize({status:"History",customer_choice:"Replace Item",approved_at:"2026-10-17"}),false);
});
test("Lost SMS identifies ToolTag, includes the dedicated secure choice link and rejects external paths",()=>{
 const path="/lost/"+"a".repeat(64);
 assert.equal(renderSms("LOST_RESOLUTION",{job_code:"TT-J-2026-00123",action_path:path},"https://tooltag.martinlab.studio"),"ToolTag: Your order TT-J-2026-00123 moved to Lost Item Resolution. Details: https://tooltag.martinlab.studio"+path);
 assert.throws(()=>renderSms("LOST_RESOLUTION",{job_code:"TT-J-2026-00123",action_path:"//evil.example/lost/abcdabcd"},"https://tooltag.example"));
});

test("Lost payment details validate methods and use authenticated encryption without retaining card fields",async()=>{
 const {validateLostPaymentDetails,encryptLostPaymentDetails,decryptLostPaymentDetails}=await import("../src/lib/security/lost-payment-details");
 const previous=process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY;
 process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY=Buffer.alloc(32,7).toString("base64");
 try{
  const clean=validateLostPaymentDetails({method:"Bank Transfer",holder:"Test Owner",routing:"021000021",account:"123456789"},"Cash");
  const encrypted=encryptLostPaymentDetails(clean,"lost-test");assert.equal(encrypted.includes("123456789"),false);assert.deepEqual(decryptLostPaymentDetails(encrypted,"lost-test"),clean);
  assert.throws(()=>decryptLostPaymentDetails(encrypted,"different-case"));
  assert.throws(()=>validateLostPaymentDetails({method:"Venmo",holder:"Test Owner",handle:"@test"},"Zelle"),/original/);
  assert.throws(()=>validateLostPaymentDetails({...clean,routing:"111111111"},"Cash"),/routing/);
  assert.throws(()=>validateLostPaymentDetails({method:"Card",holder:"Test Owner"},"Cash"),/original/);
  assert.deepEqual(validateLostPaymentDetails({method:"Card",holder:"Test Owner",account:"4242424242424242"},"Card"),{method:"Card",holder:"Test Owner"});
  delete process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY;assert.throws(()=>encryptLostPaymentDetails(clean,"lost-test"),/not configured/);
 }finally{if(previous===undefined)delete process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY;else process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY=previous;}
});

test("Sales Tax quarters reset at Denver calendar boundaries and retain accumulated recorded tax", async () => {
  const {salesTaxQuarter,salesTaxSummary} = await import("../src/lib/domain/sales-tax-summary");
  assert.equal(salesTaxQuarter(new Date("2027-01-01T06:59:59Z")).label,"Q4 2026");
  assert.equal(salesTaxQuarter(new Date("2027-01-01T07:00:00Z")).label,"Q1 2027");
  assert.equal(salesTaxQuarter(new Date("2026-04-01T05:59:59Z")).label,"Q1 2026");
  assert.equal(salesTaxQuarter(new Date("2026-04-01T06:00:00Z")).label,"Q2 2026");
  const records = [
    {type:"SALE",amount:"107.45",revenue:"100.00",date:"2026-09-30"},
    {type:"SALE",amount:"214.90",revenue:"200.00",date:"2026-10-01"},
    {type:"REFUND",amount:"53.73",revenue:"-50.00",date:"2026-10-02"},
    {type:"REFUND",amount:"25.00",revenue:"0.00",date:"2026-10-03"},
    {type:"SALE",amount:"10.00",revenue:"10.00",date:"2026-10-04"},
  ];
  const q4=salesTaxSummary(records,new Date("2026-10-17T12:00:00Z"));
  assert.equal(q4.accumulated,"18.62");assert.equal(q4.current,"11.17");
  const q1=salesTaxSummary(records,new Date("2027-01-01T07:00:00Z"));
  assert.equal(q1.accumulated,"18.62");assert.equal(q1.current,"0.00");
});

test("Sales Tax uses configurable annual quarter dates, including fiscal-year rollover", async () => {
  const {salesTaxQuarter,validateTaxQuarters,salesTaxSummary} = await import("../src/lib/domain/sales-tax-summary");
  const starts=["10-15","01-15","04-15","07-15"];
  assert.equal(salesTaxQuarter(new Date("2027-01-15T06:59:59Z"),starts).label,"Q1 2026");
  assert.equal(salesTaxQuarter(new Date("2027-01-15T07:00:00Z"),starts).label,"Q2 2027");
  assert.deepEqual(salesTaxQuarter(new Date("2026-10-17T12:00:00Z"),starts),{start:"2026-10-15",end:"2027-01-15",label:"Q1 2026"});
  for (const invalid of [["01-01","01-01","07-01","10-01"],["02-29","04-01","07-01","10-01"],["02-30","04-01","07-01","10-01"],["01-01","10-01","07-01","04-01"]]) assert.throws(()=>validateTaxQuarters(invalid));
  const records=[{type:"SALE",amount:"107.45",revenue:"100.00",date:"2026-10-14"}];
  assert.equal(salesTaxSummary(records,new Date("2026-10-17T12:00:00Z"),starts).current,"0.00");
  assert.equal(salesTaxSummary(records,new Date("2026-10-17T12:00:00Z"),starts).accumulated,"7.45");
});

test("Transactions validate filters and preserve them across twenty-record pages",async()=>{
  const {transactionFilters,transactionPageUrl,TRANSACTION_PAGE_SIZE}=await import("../src/lib/domain/transaction-filters");
  assert.equal(TRANSACTION_PAGE_SIZE,20);
  const filters=transactionFilters({q:"TEST- drill",type:"EXPENSE",status:"Active",from:"2026-10-01",to:"2026-10-31",page:"2"});
  const url=new URL(transactionPageUrl(filters,3),"https://example.test");
  assert.equal(url.searchParams.get("q"),"TEST- drill");assert.equal(url.searchParams.get("type"),"EXPENSE");assert.equal(url.searchParams.get("from"),"2026-10-01");assert.equal(url.searchParams.get("page"),"3");
  const bad=transactionFilters({q:'abc%,status.eq.Voided(*)',type:"unknown",status:"unknown",from:"2026-02-30",account:"not-a-uuid",page:"-2"});
  assert.equal(bad.type,"");assert.equal(bad.status,"");assert.equal(bad.from,"");assert.equal(bad.account,"");assert.equal(bad.page,1);assert.equal(/[,*()%]/.test(bad.q),false);
});

test("Expense proof rejects oversized, unsupported and mislabeled files before registration",async()=>{
 const {expenseProofError}=await import("../src/lib/domain/expense-proof");
 assert.equal(expenseProofError({size:3,type:"image/jpeg"},new Uint8Array([255,216,255])),null);
 assert.ok(expenseProofError({size:4*1024*1024,type:"image/jpeg"}));
 assert.ok(expenseProofError({size:20,type:"application/pdf"}));
 assert.ok(expenseProofError({size:3,type:"image/png"},new Uint8Array([255,216,255])));
 assert.ok(expenseProofError({size:0,type:"image/jpeg"}));
});

test("Finance lists keep filters across pages and use Denver date boundaries through DST",async()=>{
 const {financeFilters,financePageUrl,denverDateBoundary}=await import("../src/lib/domain/finance-list");
 const filters=financeFilters({q:"TT-S-2026",status:"Paid",page:"3",from:"2026-10-01"},[{name:"status",label:"Status",options:["Paid","Open"]}]);
 assert.equal(filters.values.status,"Paid");assert.equal(filters.page,3);
 const url=new URL(financePageUrl('/app/finance/sales',filters.values,4),'https://example.test');
 assert.equal(url.searchParams.get('status'),'Paid');assert.equal(url.searchParams.get('q'),'TT-S-2026');assert.equal(url.searchParams.get('page'),'4');assert.equal(url.searchParams.get('from'),'2026-10-01');
 assert.equal(financeFilters({method:'Cash'},[{name:'method',label:'Method',options:['Zelle','Check']}]).values.method,'');
 assert.equal(denverDateBoundary('2026-03-08'),'2026-03-08T07:00:00.000Z');
 assert.equal(denverDateBoundary('2026-03-08',true),'2026-03-09T06:00:00.000Z');
 assert.equal(denverDateBoundary('2026-11-01'),'2026-11-01T06:00:00.000Z');
 assert.equal(denverDateBoundary('2026-11-01',true),'2026-11-02T07:00:00.000Z');
});

test("Finance pagination counts the complete filtered set, caps pages at twenty, and clamps stale page numbers",async()=>{
 const {financePage}=await import("../src/lib/domain/finance-list");
 type Response={data:{id:number}[]|null;count:number|null;error:null};
 type Query=Promise<Response>&{range:(from:number,to:number)=>Query};
 const records=Array.from({length:241},(_,id)=>({id}));
 const ranges:number[][]=[];
 function make(head:boolean,from=0,to=records.length-1):Query{return Object.assign(Promise.resolve({data:head?null:records.slice(from,to+1),count:head?records.length:null,error:null}),{range:(a:number,b:number)=>{ranges.push([a,b]);return make(head,a,b);}});}
 const second=await financePage(head=>make(head),2);
 assert.equal(second.rows.length,20);assert.equal(second.rows[0].id,20);assert.equal(second.total,241);
 const last=await financePage(head=>make(head),999);assert.equal(last.page,13);assert.equal(last.rows.length,1);assert.equal(last.rows[0].id,240);
 assert.deepEqual(ranges,[[20,39],[240,259]]);
});

test("List pagination keeps urgency order, twenty cases per page and safe stale-page bounds",async()=>{
 const {paginateList}=await import("../src/lib/domain/list-pagination");
 const cases=Array.from({length:43},(_,index)=>`case-${index}`);
 const second=paginateList(cases,"2");
 assert.deepEqual(second.items,cases.slice(20,40));assert.equal(second.total,43);
 assert.equal(second.start,21);assert.equal(second.end,40);assert.equal(second.pages,3);
 assert.deepEqual(paginateList(cases,"999").items,cases.slice(40));
 for(const invalid of [undefined,"-1","0","1.5","NaN","Infinity"])assert.equal(paginateList(cases,invalid).page,1);
 assert.deepEqual(paginateList([],"4"),{items:[],total:0,pages:1,page:1,start:0,end:0});
});

test("SMS activation is production-only, explicitly overridable, and safe without configuration",async()=>{
 const {smsMode}=await import("../src/lib/integrations/sms");
 assert.equal(smsMode({},true),"preview");assert.equal(smsMode({VERCEL_ENV:"preview"},true),"preview");
 assert.equal(smsMode({VERCEL_ENV:"production"},false),"preview");assert.equal(smsMode({VERCEL_ENV:"production"},true),"live");
 assert.equal(smsMode({VERCEL_ENV:"production",TOOLTAG_SMS_MODE:"preview"},true),"preview");
 assert.equal(smsNetworkAllowed({VERCEL_ENV:"production"},true),true);
 const {dispatchSms}=await import("../src/lib/integrations/sms-dispatch");
 const calls:string[]=[];
 const db={rpc:async(name:string)=>{calls.push(name);return {data:{enabled:false},error:null};}};
 const result=await dispatchSms(db as unknown as Parameters<typeof dispatchSms>[0]);
 assert.deepEqual(result,{sent:0,skipped:0,failed:0});assert.deepEqual(calls,["sms_runtime_config"]);
 const broken={rpc:async()=>{throw new Error("offline");}};
 assert.deepEqual(await dispatchSms(broken as unknown as Parameters<typeof dispatchSms>[0]),{sent:0,skipped:0,failed:0});
});

test('Owner-only evidence fallback permits the authorized expense recorder without granting empty permissions to employees',async()=>{
 const {canAny,evidencePermissions,canMutate}=await import('../src/lib/auth/permissions');
 const owner={owner:true,blocks:[]},employee={owner:false,blocks:['payments.record']};
 assert.equal(canMutate(owner,'movement'),true);assert.equal(canAny(owner,evidencePermissions('Other')),true);
 assert.equal(canMutate(employee,'movement'),false);assert.equal(canAny(employee,evidencePermissions('Other')),false);
});
test('Get Tagged tool photos are optional and only accept UUID references',()=>{
 const request=emptyGetTaggedRequest();request.contact.name='Test Photo';request.contact.email='test-photo@example.test';
 request.items[0]={...request.items[0],article:'Drill',brand:'Test',marks:[{...request.items[0].marks[0],location:'Side',text:'Test'}]};
 assert.equal(getTaggedRequestSchema.parse(request).items[0].photo_id,'');
 request.items[0].photo_id='00000000-0000-4000-8000-000000000001';assert.equal(getTaggedRequestSchema.parse(request).items[0].photo_id,request.items[0].photo_id);
 assert.equal(getTaggedRequestSchema.safeParse({...request,items:[{...request.items[0],photo_id:'https://foreign.test/image'}]}).success,false);
});
