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

let customerSequence = 1000;

async function createCustomer(name: string, suffix: string) {
  customerSequence++;
  const phone = `801555${String(customerSequence).padStart(4, "0")}`;
  const id = await rpc("save_customer", {
    unit_id: unit,
    name,
    email: `${suffix}@example.test`,
    phone,
    address: "101 Personal Way, Draper, UT 84020",
    company_name: "Test Company",
    company_email: `company-${suffix}@example.test`,
    company_phone: "8015550111",
    company_address: "202 Company Way, Draper, UT 84020",
  });
  return { id, phone };
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


function decodeCopyText(field: string) {
  return field
    .replace(/\\\\([btnrfv\\\\])/g, (_match, escape: string) => {
      const values: Record<string, string> = {
        b: "\b",
        t: "\t",
        n: "\n",
        r: "\r",
        f: "\f",
        v: "\v",
        "\\": "\\",
      };
      return values[escape] ?? escape;
    })
    .replace(/\\\\([0-7]{1,3})/g, (_match, octal: string) =>
      String.fromCharCode(Number.parseInt(octal, 8)),
    );
}

function sqlLiteralFromCopy(field: string) {
  if (field === "\\N") return "null";
  const decoded = decodeCopyText(field);
  return "'" + decoded.replaceAll("'", "''") + "'";
}

function pgDumpForPGlite(sql: string) {
  const input = sql.split("\n");
  const output: string[] = [];

  for (let index = 0; index < input.length; index++) {
    const line = input[index];
    const match = line.match(/^COPY (.+?) \((.+)\) FROM stdin;$/);
    if (!match) {
      output.push(line);
      continue;
    }

    const table = match[1];
    const columns = match[2];
    const rows: string[] = [];

    index++;
    while (index < input.length && input[index] !== "\\.") {
      if (input[index] !== "") {
        rows.push(
          "(" +
            input[index]
              .split("\t")
              .map(sqlLiteralFromCopy)
              .join(",") +
            ")",
        );
      }
      index++;
    }

    if (rows.length) {
      output.push(
        `insert into ${table} (${columns}) values\n${rows.join(",\n")};`,
      );
    }
  }

  return output.join("\n");
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
     create role supabase_admin;
     create schema auth;
     create table auth.users(id uuid primary key);
     create function auth.uid() returns uuid language sql stable
       as 'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
     create function auth.role() returns text language sql stable
       as 'select current_setting(''request.jwt.claim.role'',true)';
     grant usage on schema auth to anon,authenticated,service_role;
     grant execute on all functions in schema auth to anon,authenticated,service_role;

     create schema storage;
     create table storage.buckets(
       id text primary key,
       name text not null,
       owner uuid,
       created_at timestamptz default now(),
       updated_at timestamptz default now(),
       public boolean not null default false,
       avif_autodetection boolean not null default false,
       file_size_limit bigint,
       allowed_mime_types text[],
       owner_id text,
       type text default 'STANDARD',
       versioning_status text default 'DISABLED',
       lifecycle_configuration jsonb,
       lifecycle_configuration_generation bigint
     );
     create table storage.objects(
       id uuid primary key default gen_random_uuid(),
       bucket_id text not null,
       name text not null
     );
     alter table storage.objects enable row level security;
     create function storage.foldername(name text)
     returns text[] language sql immutable
       as 'select string_to_array(name,''/'')';
     grant usage on schema storage to anon,authenticated,service_role;
     grant select,insert,update,delete on storage.objects to service_role;
     grant select on storage.objects to authenticated;`,
  );

  const baselineFiles = (
    await readdir("supabase/migrations")
  )
    .filter((file) => file.includes("_baseline_") && file.endsWith(".sql"))
    .sort();

  assert.equal(
    baselineFiles.length,
    6,
    "The clean logistics fixture must start from the six canonical baselines.",
  );

  for (const file of baselineFiles) {
    await db.exec(
      pgDumpForPGlite(
        await readFile(`supabase/migrations/${file}`, "utf8"),
      ),
    );
  }

  for (const file of (await readdir("supabase/migrations")).filter(file => file.endsWith(".sql") && !file.includes("_baseline_")).sort()) {
    await db.exec(await readFile(`supabase/migrations/${file}`, "utf8"));
  }

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
  const quote = await createQuote(customer.id, "40.00");
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
    String(beforeSnapshot.policy.version),
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
    "select id from public.accounts where unit_id=$1 order by id limit 1",
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
  const quote = await createQuote(customer.id, "80.00");
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
  assert.equal(stop.customer_phone, customer.phone);
  assert.equal(stop.window, "08:00-12:00");

  await assert.rejects(
    () => value("select public.advance_job($1,'start')", [accepted.job_id]),
    /Logistics fee must be confirmed/,
  );

  const secondCustomer = await createCustomer(
    "Capacity Customer",
    "capacity-customer",
  );
  const secondQuote = await createQuote(secondCustomer.id, "30.00");
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
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Not Started",
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
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Not Started",
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
  const quote = await createQuote(customer.id, "55.00");
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

  const pickupQuote = await createQuote(customer.id, "20.00");
  await db.query(
    `update public.quotes
     set source='public_get_tagged',
         intake_details='{"service":{"method":"Pickup","address":"606 Intake Way, Draper, UT 84020"}}'::jsonb,
         intake_reviewed_at=now()
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

  const dropoffQuote = await createQuote(customer.id, "21.00");
  await db.query(
    `update public.quotes
     set source='public_get_tagged',
         intake_details='{"service":{"method":"Drop-off","address":""}}'::jsonb,
         intake_reviewed_at=now()
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


test("Card stays pending until a matching provider confirmation and then opens the backend gate", async () => {
  const account = await value<string>(
    "select id from public.accounts where unit_id=$1 order by id limit 1",
    [unit],
  );
  await db.query(
    "update public.unit_settings set payment_account_id=$2 where unit_id=$1",
    [unit, account],
  );

  const customer = await createCustomer("Card Logistics", "card-logistics");
  const quote = await createQuote(customer.id, "45.00");
  const token = await value<string>("select public.send_quote($1)", [quote]);
  const accepted = await acceptWithLogistics(token, {
    option_code: "dropoff_delivery",
    delivery_address: "707 Card Delivery Ave, Draper, UT 84020",
  });

  const attempt = "80000000-0000-0000-0000-000000000093";
  const prepared = await value<{ amount: number; scope: string; method: string }>(
    "select public.prepare_logistics_payment($1,'fee_only','Card',$2)",
    [token, attempt],
  );
  assert.equal(Number(prepared.amount), 9.99);
  assert.equal(prepared.scope, "fee_only");
  assert.equal(prepared.method, "Card");

  await value("select public.attach_logistics_card_session($1,$2,$3)", [
    token,
    attempt,
    "cs_test_tooltag_93",
  ]);

  assert.equal(
    await value(
      "select payment_status from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    "pending",
  );

  await assert.rejects(
    () => value("select public.advance_job($1,'start')", [accepted.job_id]),
    /Logistics fee must be confirmed/,
  );

  await db.exec(
    "select set_config('request.jwt.claim.role','service_role',false)",
  );

  await assert.rejects(
    () =>
      value(
        "select public.confirm_logistics_card_payment($1,$2,$3::numeric)",
        [attempt, "cs_test_wrong", "9.99"],
      ),
    /does not match/,
  );

  const confirmed = await value<{
    status: string;
    confirmed_amount: number;
  }>(
    "select public.confirm_logistics_card_payment($1,$2,$3::numeric)",
    [attempt, "cs_test_tooltag_93", "9.99"],
  );

  assert.equal(confirmed.status, "paid_confirmed");
  assert.equal(Number(confirmed.confirmed_amount), 9.99);

  await db.exec(
    "select set_config('request.jwt.claim.role','authenticated',false)",
  );

  assert.equal(
    await value(
      "select payment_status from public.quote_logistics where quote_id=$1",
      [quote],
    ),
    "paid_confirmed",
  );
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Not Started",
  );
  assert.equal(
    await value(
      "select payment_method from public.transactions where reference=$1",
      ["STRIPE:cs_test_tooltag_93"],
    ),
    "Card",
  );

  await value("select public.advance_job($1,'start')", [accepted.job_id]);
  assert.equal(
    await value("select work_stage from public.jobs where id=$1", [
      accepted.job_id,
    ]),
    "Receiving Evidence",
  );
});

async function readyReturn(suffix: string) {
  const customer = await createCustomer(`Route ${suffix}`, suffix);
  const quote = await createQuote(customer.id);
  const token = await value<string>("select public.send_quote($1)", [quote]);
  const accepted = await acceptWithLogistics(token, {option_code:"dropoff_delivery",delivery_address:"101 Route Street, Draper UT"});
  await db.query("update public.quote_logistics set payment_status='paid_confirmed' where quote_id=$1", [quote]);
  await db.query("update public.pick_return_orders set fee_status='Confirmed',hold_until_paid=false where job_id=$1", [accepted.job_id]);
  await db.query("update public.job_items set stage='Finished' where job_id=$1", [accepted.job_id]);
  await db.query("update public.jobs set work_stage='Delivery In Progress' where id=$1", [accepted.job_id]);
  const statusToken=await value<string>("select private.ensure_job_status_link($1)",[accepted.job_id]);
  return {job:accepted.job_id,token:statusToken};
}

test("Route slots include both endpoints, share Return ETAs and reject a foreign token",async()=>{
 const {job,token}=await readyReturn("slots");
 const date=await value<string>("select ((now() at time zone 'America/Denver')::date+14)::text");
 const result=await value<{slots:{eta:string;label:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[job,date,token]);
 assert.equal(result.slots.length,13);
 assert.equal(result.slots[0].label,"2:00 PM");
 assert.equal(result.slots.at(-1)?.label,"6:00 PM");
 await assert.rejects(value("select public.route_schedule($1,'Return',$2,$3,'foreign-token')",[job,date,result.slots[0].eta]),/Access denied/);
});

test("First missed Return creates no fee or retry route; customer can choose free shop pickup",async()=>{
 const {job,token}=await readyReturn("miss-shop");
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 assert.equal(Number(await value("select count(*) from public.delivery_attempt_fees where job_id=$1",[job])),0);
 assert.equal(await value("select return_window_start from public.pick_return_orders where job_id=$1",[job]),null);
 await value("select public.choose_shop_pickup($1,$2)",[job,token]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Shop Pickup");
});

test("Chosen second Return costs separately and cannot be scheduled before confirmation",async()=>{
 const {job,token}=await readyReturn("miss-retry");
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 await value("select public.choose_second_return($1,$2)",[job,token]);
 await value("select public.choose_second_return($1,$2)",[job,token]);
 assert.equal(Number(await value("select count(*) from public.delivery_attempt_fees where job_id=$1",[job])),1);
 assert.equal(Number(await value("select amount from public.delivery_attempt_fees where job_id=$1",[job])),10);
 assert.equal(await value("select return_window_start from public.pick_return_orders where job_id=$1",[job]),null);
 const date=await value<string>("select ((now() at time zone 'America/Denver')::date+14)::text");
 const availability=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[job,date,token]);
 await assert.rejects(value("select public.route_schedule($1,'Return',$2,$3,$4)",[job,availability.day,availability.slots[0].eta,token]),/Confirm the second Return payment/);
});

test("Confirmed retry payment schedules once; second miss is nonrefundable and forbids a third trip",async()=>{
 const {job,token}=await readyReturn("retry-paid");
 let stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 await value("select public.choose_second_return($1,$2)",[job,token]);
 const due=await value<number>("select balance_due from public.job_commercial_totals where id=$1",[job]);
 const request=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,job,due]);
 await value("select public.confirm_payment_request($1)",[request]);
 stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 assert.ok(stop);
 await value("select public.confirm_payment_request($1)",[request]);
 assert.equal(Number(await value("select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job])),1);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Shop Pickup");
 assert.equal(Number(await value("select refunded from public.sale_balances b join public.delivery_attempt_fees f on f.sale_id=b.transaction_id where f.job_id=$1",[job])),0);
 await assert.rejects(value("select public.choose_second_return($1,$2)",[job,token]),/unavailable/);
});

test("Cash remains unpaid until the driver confirms collection; handover is blocked beforehand",async()=>{
 const {job,token}=await readyReturn("cash-gate");
 await value("select public.prepare_route_payment($1,'Cash',gen_random_uuid())",[token]);
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await assert.rejects(value("select public.advance_pick_return_stop($1,'delivered')",[stop]),/Collect and confirm/);
 await value("select public.collect_route_cash($1)",[stop]);
 await value("select public.collect_route_cash($1)",[stop]);
 assert.equal(Number(await value("select balance_due from public.job_commercial_totals where id=$1",[job])),0);
 assert.equal(Number(await value("select count(*) from public.payment_requests where request_key=$1",[stop])),1);
});

test("Pickup calendar has 13 inclusive unique slots and worker releases an unconfirmed 48h slot",async()=>{
 await db.query("update public.unit_settings set max_pickup_stops_per_saturday=10 where unit_id=$1",[unit]);
 const customer=await createCustomer("Pickup cutoff","pickup-cutoff");
 const quote=await createQuote(customer.id);
 const review=await value<string>("select public.send_quote($1)",[quote]);
 const accepted=await acceptWithLogistics(review,{option_code:"pickup_delivery",pickup_address:"101 Pickup Way, Draper UT",saturday_date:futureSaturday()});
 const job=accepted.job_id;
 const token=await value<string>("select private.ensure_job_status_link($1)",[job]);
 const date=await value<string>("select ((now() at time zone 'America/Denver')::date+14)::text");
 const a=await value<{slots:{eta:string;label:string}[];day:string}>("select public.route_availability($1,'Pickup',$2,$3)",[job,date,token]);
 assert.equal(a.slots.length,13);
 assert.equal(a.slots[0].label,"8:00 AM");
 assert.equal(a.slots.at(-1)?.label,"12:00 PM");
 const old=await value<string>("update public.pick_return_orders set pickup_window_start=now()+interval '47 hours',pickup_window_end=now()+interval '51 hours',pickup_eta=null where job_id=$1 returning pickup_window_start::text",[job]);
 await value("select private.reconcile_pickups()");
 const next=await value<string>("select pickup_window_start::text from public.pick_return_orders where job_id=$1",[job]);
 assert.ok(new Date(next)>new Date(old));
 assert.equal(Number(await value("select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Pickup' and s.status not in ('Cancelled','Failed')",[job])),0);
});

test("Logistics proof stays tied to its payment and private proxy metadata requires staff or owner token",async()=>{
 const customer=await createCustomer("Proof owner","proof-owner");
 const quote=await createQuote(customer.id);
 const review=await value<string>("select public.send_quote($1)",[quote]);
 const accepted=await acceptWithLogistics(review,{option_code:"dropoff_delivery",delivery_address:"101 Proof Lane, Draper UT"});
 const attempt=await value<string>("select gen_random_uuid()");
 await value("select public.prepare_logistics_payment($1,'fee_only','Zelle',$2)",[review,attempt]);
 const path=`${unit}/${attempt}.png`;
 await db.query("insert into storage.objects(bucket_id,name) values('payment-proofs',$1)",[path]);
 const submitted=await value<{payment_request_id:string}>("select public.mark_logistics_manual_with_proof($1,$2,$3)",[review,attempt,path]);
 assert.equal(await value("select proof_path from public.payment_requests where id=$1",[submitted.payment_request_id]),path);
 const code=await value<string>("select code from public.jobs where id=$1",[accepted.job_id]);
 const owner=await value<string>("select private.ensure_job_status_link($1)",[accepted.job_id]);
 await db.query("select set_config('request.jwt.claim.sub','',false)");
 try {
  await assert.rejects(value("select public.payment_proof_file($1,$2,'wrong')",[code,submitted.payment_request_id]),/File unavailable/);
  const file=await value<{path:string}>("select public.payment_proof_file($1,$2,$3)",[code,submitted.payment_request_id,owner]);
  assert.equal(file.path,path);
 } finally {await db.query("select set_config('request.jwt.claim.sub',$1,false)",[admin]);}
});

test("Return ETAs can be shared up to configured daily capacity; full day moves to next Sunday",async()=>{
 const a=await readyReturn("capacity-a"),b=await readyReturn("capacity-b"),c=await readyReturn("capacity-c");
 await db.query("update public.unit_settings set max_delivery_stops_per_sunday=2 where unit_id=$1",[unit]);
 try {
  const date=await value<string>("select ((now() at time zone 'America/Denver')::date+60)::text");
  const slots=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[a.job,date,a.token]);
  await value("select public.route_schedule($1,'Return',$2,$3,$4)",[a.job,slots.day,slots.slots[0].eta,a.token]);
  await value("select public.route_schedule($1,'Return',$2,$3,$4)",[b.job,slots.day,slots.slots[0].eta,b.token]);
  const full=await value<{day:string;moved:boolean}>("select public.route_availability($1,'Return',$2,$3)",[c.job,slots.day,c.token]);
  assert.equal(full.moved,true);
  assert.ok(full.day>slots.day);
 } finally {await db.query("update public.unit_settings set max_delivery_stops_per_sunday=20 where unit_id=$1",[unit]);}
});

test("24h unpaid Return stays pending and assigned; 1h cutoff moves it and blocks late Cash choice",async()=>{
 const {job,token}=await readyReturn("return-cutoffs");
 const originalStop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_orders set return_window_start=now()+interval '23 hours' where job_id=$1",[job]);
 await value("select private.reconcile_delivery($1)",[job]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Pending Delivery");
 assert.equal(await value("select status from public.pick_return_stops where id=$1",[originalStop]),"Scheduled");
 const cutoff=await value<string>("update public.pick_return_orders set return_window_start=now()+interval '59 minutes' where job_id=$1 returning return_window_start::text",[job]);
 await assert.rejects(value("select public.prepare_route_payment($1,'Cash',gen_random_uuid())",[token]),/cutoff/);
 await value("select private.reconcile_delivery($1)",[job]);
 const next=await value<string>("select return_window_start::text from public.pick_return_orders where job_id=$1",[job]);
 assert.ok(new Date(next)>new Date(cutoff));
 assert.equal(Number(await value("select count(*) from public.notifications where entity_id=$1 and dedupe_key like 'return-cutoff:%'",[job])),1);
});

test("Stops advance sequentially, but route closure requires explicit confirmation",async()=>{
 const a=await readyReturn("sequential-a"),b=await readyReturn("sequential-b");
 const date=await value<string>("select ((now() at time zone 'America/Denver')::date+90)::text");
 const available=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[a.job,date,a.token]);
 const first=await value<string>("select public.route_schedule($1,'Return',$2,$3,$4)",[a.job,available.day,available.slots[0].eta,a.token]);
 const second=await value<string>("select public.route_schedule($1,'Return',$2,$3,$4)",[b.job,available.day,available.slots[1].eta,b.token]);
 const route=await value<string>("select route_id from public.pick_return_stops where id=$1",[first]);
 await assert.rejects(value("select public.advance_pick_return_stop($1,'en-route')",[second]),/previous stop/);
 await db.query("update public.pick_return_orders set delivery_payment_method='Cash' where job_id=$1",[b.job]);
 await db.query("update public.pick_return_stops set status='Completed',completed_at=now() where id=$1",[first]);
 const seq=await value<number>("select sequence from public.pick_return_stops where id=$1",[first]);
 await value("select private.activate_next_route_stop($1,$2)",[route,seq]);
 assert.equal(await value("select status from public.pick_return_stops where id=$1",[second]),"En Route");
 await assert.rejects(value("select public.confirm_pick_return_route($1)",[route]),/Resolve every stop/);
 await db.query("update public.pick_return_stops set status='Completed',completed_at=now() where id=$1",[second]);
 const finalSeq=await value<number>("select sequence from public.pick_return_stops where id=$1",[second]);
 await value("select private.activate_next_route_stop($1,$2)",[route,finalSeq]);
 assert.notEqual(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
 await value("select public.confirm_pick_return_route($1)",[route]);
 assert.equal(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
});

async function driverPickupFixture(suffix:string){
 await db.query("update public.unit_settings set max_pickup_stops_per_saturday=10 where unit_id=$1",[unit]);
 const customer=await createCustomer(suffix,suffix);const quote=await createQuote(customer.id);
 const review=await value<string>("select public.send_quote($1)",[quote]);
 const accepted=await acceptWithLogistics(review,{option_code:"pickup_delivery",pickup_address:"101 Pickup Way",saturday_date:futureSaturday()});
 const job=accepted.job_id;const token=await value<string>("select private.ensure_job_status_link($1)",[job]);
 await db.query("update public.pick_return_orders set fee_status='Confirmed' where job_id=$1",[job]);
 await db.query("update public.quote_logistics set payment_status='paid_confirmed' where quote_id=$1",[quote]);
 const day=await value<string>("select ((now() at time zone 'America/Denver')::date+150)::text");
 const a=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Pickup',$2,$3)",[job,day,token]);
 const stop=await value<string>("select public.route_schedule($1,'Pickup',$2,$3,$4)",[job,a.day,a.slots[0].eta,token]);
 return {job,token,stop};
}

test("Pickup arrival notifies once, enforces five minutes and persists customer-coming / wait-more",async()=>{
 const coming=await driverPickupFixture("driver-coming");
 await value("select public.pickup_driver_action($1,'en-route')",[coming.stop]);
 await value("select public.pickup_driver_action($1,'arrived')",[coming.stop]);
 await assert.rejects(value("select public.pickup_driver_action($1,'wait-more')",[coming.stop]),/only after timeout/);
 await value("select public.pickup_driver_action($1,'customer-coming')",[coming.stop]);
 await assert.rejects(value("select public.pickup_driver_action($1,'wait-more')",[coming.stop]),/only after timeout/);
 await assert.rejects(value("select public.pickup_driver_action($1,'pickup-miss')",[coming.stop]),/five-minute/);
 assert.equal(await value("select pickup_wait_until is null and customer_coming_at is not null from public.pick_return_stops where id=$1",[coming.stop]),true);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Receiving Evidence','coming-out.jpg',$2,$3,'Available')",[unit,coming.job,coming.stop]);
 await value("select public.pickup_driver_action($1,'picked-up')",[coming.stop]);
 const {job,token,stop}=await driverPickupFixture("driver-wait");
 await value("select public.pickup_driver_action($1,'en-route')",[stop]);
 await value("select public.pickup_driver_action($1,'arrived')",[stop]);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",['pickup-arrived:'+stop])),1);
 await assert.rejects(value("select public.pickup_driver_action($1,'pickup-miss')",[stop]),/five-minute/);
 await db.query("update public.pick_return_stops set pickup_wait_until=now()-interval '1 second' where id=$1",[stop]);
 await value("select public.pickup_driver_action($1,'wait-more')",[stop]);
 await assert.rejects(value("select public.pickup_driver_action($1,'pickup-miss')",[stop]),/five-minute/);
 await db.query("update public.pick_return_stops set pickup_wait_until=now()-interval '1 second' where id=$1",[stop]);
 await value("select public.pickup_driver_action($1,'pickup-miss')",[stop]);
 assert.equal(await value("select public.pickup_miss_state($1,$2)",[job,token]),true);
 assert.equal(await value("select fee_status from public.pick_return_orders where job_id=$1",[job]),"Confirmed");
 const oldDay=await value<string>("select r.route_date::text from public.pick_return_routes r join public.pick_return_stops s on s.route_id=r.id where s.id=$1",[stop]);
 const rescheduled=await value<{day:string}>("select public.pickup_miss_choice($1,$2,'reschedule')",[job,token]);
 assert.ok(rescheduled.day>oldDay);
 assert.equal(await value("select public.pickup_miss_state($1,$2)",[job,token]),false);
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Scheduled'",[job])),1);
});

test("Pickup hold blocks collection through new and original RPC; pickup miss cancellation retains fee",async()=>{
 const {job,token,stop}=await driverPickupFixture("driver-hold");
 await value("select public.pickup_driver_action($1,'en-route')",[stop]);
 await value("select public.pickup_driver_action($1,'arrived')",[stop]);
 await db.query("update public.jobs set work_stage='Cancellation Requested / Production Hold' where id=$1",[job]);
 await assert.rejects(value("select public.pickup_driver_action($1,'picked-up')",[stop]),/hold/);
 await assert.rejects(db.query("update public.pick_return_stops set status='Completed' where id=$1",[stop]),/Hold/);
 await db.query("update public.jobs set work_stage='Not Started' where id=$1",[job]);
 await db.query("update public.pick_return_stops set pickup_wait_until=now()-interval '1 second' where id=$1",[stop]);
 await value("select public.pickup_driver_action($1,'pickup-miss')",[stop]);
 const cancelled=await value<{cancelled:boolean;assessment:{pickup_fee_refundable:boolean}}>("select public.pickup_miss_choice($1,$2,'cancel')",[job,token]);
 assert.equal(cancelled.cancelled,true);assert.equal(cancelled.assessment.pickup_fee_refundable,false);
});

test("Picked Up starts the next Pickup stop, notifies its customer, and leaves route open until shop confirmation",async()=>{
 const a=await driverPickupFixture("driver-sequence-a"),b=await driverPickupFixture("driver-sequence-b");
 await value("select public.pickup_driver_action($1,'en-route')",[a.stop]);
 await value("select public.pickup_driver_action($1,'arrived')",[a.stop]);
 await assert.rejects(value("select public.pickup_driver_action($1,'picked-up')",[a.stop]),/receiving photos/);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Receiving Evidence','pickup-test.jpg',$2,$3,'Available')",[unit,a.job,a.stop]);
 await value("select public.pickup_driver_action($1,'picked-up')",[a.stop]);
 assert.equal(await value("select status from public.pick_return_stops where id=$1",[b.stop]),"En Route");
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",['pickup-en-route:'+b.stop])),1);
 const route=await value<string>("select route_id from public.pick_return_stops where id=$1",[a.stop]);
 await assert.rejects(value("select public.confirm_pick_return_route($1)",[route]),/Resolve every stop/);
 await value("select public.pickup_driver_action($1,'arrived')",[b.stop]);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Receiving Evidence','pickup-test-b.jpg',$2,$3,'Available')",[unit,b.job,b.stop]);
 await value("select public.pickup_driver_action($1,'picked-up')",[b.stop]);
 assert.equal(await value("select confirmed_at is null from public.pick_return_routes where id=$1",[route]),true);
 await value("select public.confirm_pick_return_route($1)",[route]);
 assert.equal(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
});
