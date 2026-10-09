import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readdir, readFile } from "node:fs/promises";

const db = new PGlite();
const unit = "10000000-0000-0000-0000-000000000002";
const admin = "90000000-0000-0000-0000-000000000091";

async function value<T = string>(sql: string, args: unknown[] = []): Promise<T> {
  const result = await db.query<Record<string, T>>(sql, args);
  return Object.values(result.rows[0])[0];
}

async function rpc(name: string, payload: unknown) {
  return value<string>(`select public.${name}($1::jsonb)`, [
    JSON.stringify(payload),
  ]);
}

async function createCustomer(name: string, suffix: string) {
  return rpc("save_customer", {
    unit_id: unit,
    name,
    email: `${suffix}@example.test`,
    phone: "8015550199",
    address: "101 Personal Way, Draper, UT 84020",
    company_name: "Test Company",
    company_email: `company-${suffix}@example.test`,
    company_phone: "8015550111",
    company_address: "202 Company Way, Draper, UT 84020",
  });
}

async function createQuote(customerId: string, amount = "40.00") {
  return rpc("create_quote", {
    unit_id: unit,
    customer_id: customerId,
    items: [
      {
        article: "Battery",
        quantity: 1,
        engraving_type: "Text",
        engraving_text: "TOOLTAG",
        unit_price: amount,
        paint_fill: false,
        colors: 0,
        notes: "",
        marks: [
          {
            type: "Text",
            text: "TOOLTAG",
            url: "",
            location: "left side",
            paint_fill: false,
          },
        ],
      },
    ],
  });
}

function futureSaturday() {
  const date = new Date();
  const day = date.getUTCDay();
  let add = (6 - day + 7) % 7;
  if (add < 2) add += 7;
  date.setUTCDate(date.getUTCDate() + add);
  return date.toISOString().slice(0, 10);
}

async function acceptWithLogistics(
  token: string,
  logistics: {
    option_code: string;
    pickup_address?: string | null;
    delivery_address?: string | null;
    saturday_date?: string | null;
  },
) {
  return value<{
    job_id: string;
    payment_required: boolean;
    payment_status: string;
    payment_path: string | null;
  }>(
    "select public.accept_review_with_logistics($1,true,true,$2::jsonb)",
    [token, JSON.stringify(logistics)],
  );
}

async function makeCompletionLink(jobId: string, token: string) {
  await db.query(
    `update public.jobs
     set status='Delivered – Pending Customer Acceptance',
         work_stage='Awaiting Delivery Acceptance',
         customer_stage='Completed',
         delivered_at=now()
     where id=$1`,
    [jobId],
  );
  await db.query(
    `insert into private.public_links(token_hash,unit_id,job_id,expires_at)
     values(encode(sha256(convert_to($1,'UTF8')),'hex'),$2,$3,now()+interval '30 days')`,
    [token, unit, jobId],
  );
}

before(async () => {
  await db.exec(
    `create role anon;
     create role authenticated;
     create role service_role;
     create schema auth;
     create table auth.users(id uuid primary key);
     create function auth.uid() returns uuid language sql stable as $
       select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
     $;
     create function auth.role() returns text language sql stable as $
       select current_setting('request.jwt.claim.role',true)
     $;
     grant usage on schema auth to anon,authenticated,service_role;
     grant execute on all functions in schema auth to anon,authenticated,service_role;

     create schema storage;
     create table storage.buckets(
       id text primary key,
       name text not null,
       public boolean not null default false,
       file_size_limit bigint,
       allowed_mime_types text[]
     );
     create table storage.objects(
       id uuid primary key default gen_random_uuid(),
       bucket_id text not null,
       name text not null
     );
     alter table storage.objects enable row level security;
     create function storage.foldername(name text)
     returns text[] language sql immutable
     as $ select string_to_array(name,'/') $;
     grant usage on schema storage to anon,authenticated,service_role;
     grant select,insert,update,delete on storage.objects to service_role;
     grant select on storage.objects to authenticated;`,
  );

  for (const file of (
    await readdir("supabase/migrations-archive/pre-baseline")
  ).sort()) {
    await db.exec(
      await readFile(
        `supabase/migrations-archive/pre-baseline/${file}`,
        "utf8",
      ),
    );
  }

  await db.exec(
    await readFile(
      "supabase/migrations/20261009213000_review_logistics_payments.sql",
      "utf8",
    ),
  );

  await db.exec(
    `insert into auth.users(id) values('${admin}');
     insert into public.memberships
       select id,'${admin}','admin' from public.business_units;
     select set_config('request.jwt.claim.sub','${admin}',false);
     select set_config('request.jwt.claim.role','authenticated',false);`,
  );

  await value("select public.publish_policy($1,$2,$3)", [
    unit,
    "TEST AGREEMENT V1",
    "Test-only Agreement content. Never shown to a real customer.",
  ]);
});

after(async () => {
  await db.close();
});

test("Review requires logistics, free option needs no payment, and Agreement version stays pinned", async () => {
  const customer = await createCustomer("Free Logistics", "free-logistics");
  const quote = await createQuote(customer, "40.00");
  const token = await value<string>("select public.send_quote($1)", [quote]);

  const beforeSnapshot = await value<{
    total: number;
    logistics: {
      requires_selection: boolean;
      selected_option: string | null;
    };
    policy: { version: number };
  }>("select public.public_quote($1)", [token]);

  assert.equal(Number(beforeSnapshot.total), 40);
  assert.equal(beforeSnapshot.logistics.requires_selection, true);
  assert.equal(beforeSnapshot.logistics.selected_option, null);

  await value("select public.publish_policy($1,$2,$3)", [
    unit,
    "TEST AGREEMENT V2",
    "Second test-only version used to verify quote pinning.",
  ]);

  await db.exec("set role anon");
  await assert.rejects(
    () =>
      value(
        "select public.accept_review($1,true,true,'ignored','ignored@example.test','555')",
        [token],
      ),
    /Choose a logistics option/,
  );

  const accepted = await acceptWithLogistics(token, {
    option_code: "dropoff_pickup",
  });
  await db.exec("reset role");

  assert.equal(accepted.payment_required, false);
  assert.equal(accepted.payment_status, "not_applicable");
  assert.equal(accepted.payment_path, null);

  assert.equal(
    await value(
      "select payment_status from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    "not_applicable",
  );
  assert.ok(
    await value(
      "select locked_at is not null from public.quote_logistics where quote_id=$1",
      [quote],
    ),
  );
  assert.equal(
    Number(
      await value(
        "select amount from public.sale_versions where quote_id=$1",
        [quote],
      ),
    ),
    40,
  );
  assert.equal(
    await value(
      "select commercial_snapshot->'policy'->>'version' from public.agreements where quote_id=$1",
      [quote],
    ),
    "1",
  );
  assert.equal(
    await value(
      "select commercial_snapshot->'logistics'->>'option_name' from public.agreements where quote_id=$1",
      [quote],
    ),
    "Drop-off & Pickup",
  );

  await value("select public.advance_job($1,'start')", [accepted.job_id]);
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Receiving Evidence",
  );
});

test("Pickup selection reserves Saturday, backend blocks work, manual confirmation opens the gate and capacity is enforced", async () => {
  const saturday = futureSaturday();
  await db.query(
    "update public.unit_settings set max_pickup_stops_per_saturday=1 where unit_id=$1",
    [unit],
  );

  const account = await value<string>(
    "select id from public.accounts where unit_id=$1 order by created_at limit 1",
    [unit],
  );
  await db.query(
    `update public.unit_settings
     set zelle_email='zelle-placeholder@example.test',
         venmo_handle='@tooltag-placeholder',
         payment_account_id=$2
     where unit_id=$1`,
    [unit, account],
  );

  const customer = await createCustomer("Pickup Logistics", "pickup-logistics");
  const quote = await createQuote(customer, "80.00");
  const token = await value<string>("select public.send_quote($1)", [quote]);

  const accepted = await acceptWithLogistics(token, {
    option_code: "pickup_delivery",
    pickup_address: "303 Pickup Lane, Draper, UT 84020",
    delivery_address: null,
    saturday_date: saturday,
  });

  assert.equal(accepted.payment_required, true);
  assert.equal(accepted.payment_status, "pending");

  const logistics = await value<{
    fee_amount: number;
    pickup_address: string;
    delivery_address: string;
    saturday_date: string;
    payment_status: string;
  }>(
    `select jsonb_build_object(
       'fee_amount',fee_amount,
       'pickup_address',pickup_address,
       'delivery_address',delivery_address,
       'saturday_date',saturday_date,
       'payment_status',payment_status
     )
     from public.quote_logistics where quote_id=$1`,
    [quote],
  );
  assert.equal(Number(logistics.fee_amount), 19.99);
  assert.equal(logistics.pickup_address, "303 Pickup Lane, Draper, UT 84020");
  assert.equal(logistics.delivery_address, logistics.pickup_address);
  assert.equal(String(logistics.saturday_date), saturday);

  const stop = await value<{
    status: string;
    address: string;
    customer_email: string;
    customer_phone: string;
    window: string;
  }>(
    `select jsonb_build_object(
       'status',s.status,
       'address',s.address,
       'customer_email',s.customer_email,
       'customer_phone',s.customer_phone,
       'window',
         to_char(s.window_start at time zone 'America/Denver','HH24:MI')||
         '-'||
         to_char(s.window_end at time zone 'America/Denver','HH24:MI')
     )
     from public.pick_return_stops s
     join public.pick_return_routes r on r.id=s.route_id
     where s.job_id=$1 and r.leg='Pickup'`,
    [accepted.job_id],
  );
  assert.equal(stop.status, "Requested");
  assert.equal(stop.address, logistics.pickup_address);
  assert.equal(stop.customer_email, "pickup-logistics@example.test");
  assert.equal(stop.customer_phone, "8015550199");
  assert.equal(stop.window, "08:00-12:00");

  await assert.rejects(
    () => value("select public.advance_job($1,'start')", [accepted.job_id]),
    /Logistics fee must be confirmed/,
  );

  const secondCustomer = await createCustomer(
    "Capacity Customer",
    "capacity-customer",
  );
  const secondQuote = await createQuote(secondCustomer, "30.00");
  const secondToken = await value<string>("select public.send_quote($1)", [
    secondQuote,
  ]);
  await assert.rejects(
    () =>
      acceptWithLogistics(secondToken, {
        option_code: "pickup_only",
        pickup_address: "404 Full Route Way, Draper, UT 84020",
        saturday_date: saturday,
      }),
    /capacity/,
  );
  assert.equal(
    Number(
      await value(
        "select count(*) from public.agreements where quote_id=$1",
        [secondQuote],
      ),
    ),
    0,
  );

  const attempt = "80000000-0000-0000-0000-000000000091";
  const prepared = await value<{
    amount: number;
    method: string;
    scope: string;
    memo: string;
  }>(
    "select public.prepare_logistics_payment($1,'fee_only','Zelle',$2)",
    [token, attempt],
  );
  assert.equal(Number(prepared.amount), 19.99);
  assert.equal(prepared.method, "Zelle");
  assert.equal(prepared.scope, "fee_only");
  assert.match(prepared.memo, /^TT-J-\d{4}-\d{5} Pickup Logistics$/);

  const submitted = await value<{ status: string; payment_request_id: string }>(
    "select public.mark_logistics_manual_submitted($1,$2)",
    [token, attempt],
  );
  assert.equal(submitted.status, "pending_verification");
  assert.equal(
    await value(
      "select payment_status from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    "pending_verification",
  );

  await value("select public.confirm_payment_request($1)", [
    submitted.payment_request_id,
  ]);

  assert.equal(
    await value(
      "select payment_status from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    "paid_confirmed",
  );
  assert.equal(
    await value(
      "select status from public.pick_return_stops where job_id=$1",
      [accepted.job_id],
    ),
    "Scheduled",
  );
  assert.equal(
    Number(
      await value(
        "select count(*) from public.notifications where dedupe_key=$1",
        [`logistics-payment-confirmed:${submitted.payment_request_id}`],
      ),
    ),
    1,
  );

  await value("select public.advance_job($1,'start')", [accepted.job_id]);

  const remaining = Number(
    await value("select balance_due from public.job_commercial_totals where id=$1", [
      accepted.job_id,
    ]),
  );
  assert.ok(remaining > 0);

  const completionToken = "fee-only-completion-token";
  await makeCompletionLink(accepted.job_id, completionToken);
  await value("select public.public_completion($1,'accept')", [completionToken]);
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Payment",
  );
});

test("Full prepayment closes payment stage, and Drop-off + Delivery requires only delivery address", async () => {
  const customer = await createCustomer("Full Prepay", "full-prepay");
  const quote = await createQuote(customer, "55.00");
  const token = await value<string>("select public.send_quote($1)", [quote]);

  await assert.rejects(
    () =>
      acceptWithLogistics(token, {
        option_code: "dropoff_delivery",
      }),
    /delivery address/i,
  );

  const accepted = await acceptWithLogistics(token, {
    option_code: "dropoff_delivery",
    delivery_address: "505 Delivery Road, Sandy, UT 84070",
  });

  assert.equal(
    Number(
      await value(
        "select fee_amount from public.quote_logistics where quote_id=$1",
        [quote],
      ),
    ),
    9.99,
  );
  assert.equal(
    await value(
      "select pickup_address is null from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    true,
  );
  assert.equal(
    await value(
      "select saturday_date is null from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    true,
  );

  const attempt = "80000000-0000-0000-0000-000000000092";
  const prepared = await value<{ amount: number }>(
    "select public.prepare_logistics_payment($1,'full','Venmo',$2)",
    [token, attempt],
  );
  assert.equal(Number(prepared.amount), 64.99);

  const submitted = await value<{ payment_request_id: string }>(
    "select public.mark_logistics_manual_submitted($1,$2)",
    [token, attempt],
  );
  await value("select public.confirm_payment_request($1)", [
    submitted.payment_request_id,
  ]);

  assert.equal(
    Number(
      await value(
        "select balance_due from public.job_commercial_totals where id=$1",
        [accepted.job_id],
      ),
    ),
    0,
  );

  const completionToken = "full-prepay-completion-token";
  await makeCompletionLink(accepted.job_id, completionToken);
  const completion = await value<{
    payment: { paid_in_full: boolean; balance_due: number };
  }>("select public.public_completion($1,'accept')", [completionToken]);

  assert.equal(completion.payment.paid_in_full, true);
  assert.equal(Number(completion.payment.balance_due), 0);
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Closed",
  );
});

test("Old Get Tagged Pickup maps to Pickup & Delivery; Drop-off stays unresolved", async () => {
  const customer = await createCustomer("Legacy Intake", "legacy-intake");

  const pickupQuote = await createQuote(customer, "20.00");
  await db.query(
    `update public.quotes
     set source='public_get_tagged',
         intake_details='{"service":{"method":"Pickup","address":"606 Intake Way, Draper, UT 84020"}}'::jsonb
     where id=$1`,
    [pickupQuote],
  );
  const pickupToken = await value<string>("select public.send_quote($1)", [
    pickupQuote,
  ]);
  const pickupSnapshot = await value<{
    logistics: {
      predefined: boolean;
      requires_selection: boolean;
      selected_option: string;
    };
  }>("select public.public_quote($1)", [pickupToken]);

  assert.equal(pickupSnapshot.logistics.predefined, true);
  assert.equal(pickupSnapshot.logistics.requires_selection, false);
  assert.equal(pickupSnapshot.logistics.selected_option, "pickup_delivery");

  const dropoffQuote = await createQuote(customer, "21.00");
  await db.query(
    `update public.quotes
     set source='public_get_tagged',
         intake_details='{"service":{"method":"Drop-off","address":""}}'::jsonb
     where id=$1`,
    [dropoffQuote],
  );
  const dropoffToken = await value<string>("select public.send_quote($1)", [
    dropoffQuote,
  ]);
  const dropoffSnapshot = await value<{
    logistics: {
      predefined: boolean;
      requires_selection: boolean;
      selected_option: string | null;
    };
  }>("select public.public_quote($1)", [dropoffToken]);

  assert.equal(dropoffSnapshot.logistics.predefined, false);
  assert.equal(dropoffSnapshot.logistics.requires_selection, true);
  assert.equal(dropoffSnapshot.logistics.selected_option, null);
});
