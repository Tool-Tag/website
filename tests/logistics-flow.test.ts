import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readdir, readFile } from "node:fs/promises";

const db = new PGlite();
const unit = "10000000-0000-0000-0000-000000000002";
const admin = "90000000-0000-0000-0000-000000000091";

async function value<T = string>(sql: string, args: unknown[] = []): Promise<T> {
  const result = await db.query<Record<string, T>>(sql, args);
  return Object.values(result.rows[0]??{})[0];
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
     create table auth.users(id uuid primary key,email text);
     create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id),created_at timestamptz default now());
     create function auth.test_session() returns trigger language plpgsql as 'begin insert into auth.sessions(id,user_id) values(new.id,new.id);return new;end';
     create trigger test_session after insert on auth.users for each row execute function auth.test_session();
     create function auth.uid() returns uuid language sql stable
       as 'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
     create function auth.role() returns text language sql stable
       as 'select current_setting(''request.jwt.claim.role'',true)';
     grant usage on schema auth to anon,authenticated,service_role;
     grant execute on all functions in schema auth to anon,authenticated,service_role;

     create schema realtime;
     create table realtime.audit_test_events(topic text,event text,payload jsonb);
     create function realtime.send(payload jsonb,event text,topic text,is_private boolean default true) returns void language sql as 'insert into realtime.audit_test_events values(topic,event,payload)';
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
     grant select,insert,update on storage.objects to authenticated;`,
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

  await db.exec(
    `insert into auth.users(id) values('${admin}');
     select set_config('request.jwt.claim.session_id','${admin}',false);
     insert into public.memberships
       select id,'${admin}','admin' from public.business_units;
     select set_config('request.jwt.claim.sub','${admin}',false);
     select set_config('request.jwt.claim.role','authenticated',false);`,
  );

  for (const file of (await readdir("supabase/migrations")).filter(file => file.endsWith(".sql") && !file.includes("_baseline_")).sort()) {
    if(file==='20261013003000_manual_job_refunds.sql'){
      await value("select public.publish_policy($1,$2,$3)",[unit,'TEST BACKFILL POLICY','Test-only backfill fixture.']);
      const f=await driverReturnFixture('refund-backfill');
      const due=await value<number>('select balance_due from public.job_commercial_totals where id=$1',[f.job]);
      const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,f.job,due]);await value('select public.confirm_payment_request($1)',[payment]);
      const route=await value<string>('select route_id from public.pick_return_stops where id=$1',[f.stop]);
      const incident=await value<string>('select public.report_driver_incident($1)',[route]);await value("select public.resolve_driver_incident($1,'Continued')",[incident]);
      const comp=await value<string>('select id from public.route_compensations where incident_id=$1 and job_id=$2',[incident,f.job]);await value("select public.confirm_route_refund($1,'HISTORICAL-REFUND-TEST')",[comp]);
      const notifications=await value<number>('select count(*) from public.notifications');const transactions=await value<number>('select count(*) from public.transactions');
      await db.exec(await readFile(`supabase/migrations/${file}`, "utf8"));
      assert.equal(Number(await value('select count(*) from public.notifications')),Number(notifications));assert.equal(Number(await value('select count(*) from public.transactions')),Number(transactions));
      assert.equal(await value("select status from public.refund_requests where source_id=$1 and source_kind='Route'",[comp]),'Completed');
      assert.equal(Number(await value("select processed_amount from public.refund_requests where source_id=$1 and source_kind='Route'",[comp])),5);
    }else await db.exec(await readFile(`supabase/migrations/${file}`, "utf8"));
  }



  await db.query("update public.unit_settings set sales_tax_rate=0,shop_delivery_blocks_enabled=false,shop_pickup_blocks_enabled=false where unit_id=$1",[unit]);
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

  const sandbox = await value<string>("with p as(insert into public.physical_accounts(name) values('TEST-Stripe sandbox') returning id) insert into public.accounts(unit_id,physical_account_id,name) select $1,id,'TEST-Stripe collections' from p returning id",[unit]);
  await db.query("insert into private.stripe_test_settings(unit_id,account_id) values($1,$2)",[unit,sandbox]);
  const customer = await createCustomer("TEST-Card Logistics", "card-logistics");
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
  assert.equal(await value("select account_id from public.transactions where reference='STRIPE:cs_test_tooltag_93'"),sandbox);
  assert.equal(await value("select payment_account_id from public.unit_settings where unit_id=$1",[unit]),account);


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

test("First missed Return reserves a pending stop without a fee; free shop pickup releases it",async()=>{
 const {job,token}=await readyReturn("miss-shop");
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 assert.equal(Number(await value("select count(*) from public.delivery_attempt_fees where job_id=$1",[job])),0);
 assert.ok(await value("select return_window_start from public.pick_return_orders where job_id=$1",[job]));
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[job])),1);
 await value("select public.choose_shop_pickup($1,$2)",[job,token]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Shop Pickup");
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[job])),0);
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
 assert.ok(await value("select return_window_start from public.pick_return_orders where job_id=$1",[job]));
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[job])),1);
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
 } finally {await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[admin]);}
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
 await db.query("update public.pick_return_stops set status='Completed',completed_at=now(),customer_present_at=now() where id=$1",[first]);
 const seq=await value<number>("select sequence from public.pick_return_stops where id=$1",[first]);
 await value("select private.activate_next_route_stop($1,$2)",[route,seq]);
 assert.equal(await value("select status from public.pick_return_stops where id=$1",[second]),"En Route");
 await assert.rejects(value("select public.confirm_pick_return_route($1)",[route]),/Resolve every stop/);
 await db.query("update public.pick_return_stops set status='Completed',completed_at=now(),customer_present_at=now() where id=$1",[second]);
 const finalSeq=await value<number>("select sequence from public.pick_return_stops where id=$1",[second]);
 await value("select private.activate_next_route_stop($1,$2)",[route,finalSeq]);
 assert.notEqual(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
 await value("select public.confirm_pick_return_route($1)",[route]);
 assert.equal(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
});

async function driverPickupFixture(suffix:string,offset=150,option:"pickup_only"|"pickup_delivery"="pickup_delivery"){
 await db.query("update public.unit_settings set max_pickup_stops_per_saturday=10 where unit_id=$1",[unit]);
 const customer=await createCustomer(suffix,suffix);const quote=await createQuote(customer.id);
 const review=await value<string>("select public.send_quote($1)",[quote]);
 const accepted=await acceptWithLogistics(review,{option_code:option,pickup_address:"101 Pickup Way",saturday_date:futureSaturday()});
 const job=accepted.job_id;const token=await value<string>("select private.ensure_job_status_link($1)",[job]);
 await db.query("update public.pick_return_orders set fee_status='Confirmed' where job_id=$1",[job]);
 await db.query("update public.quote_logistics set payment_status='paid_confirmed' where quote_id=$1",[quote]);
 const day=await value<string>("select ((now() at time zone 'America/Denver')::date+$1::integer)::text",[offset]);
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
 await assert.rejects(value("select public.confirm_pick_return_route($1)",[route]),/Shop must verify/);
 const received=await db.query<{id:string}>("select i.id from public.job_items i join public.pick_return_stops s on s.job_id=i.job_id where s.route_id=$1 and s.status='Completed'",[route]);for(const item of received.rows)await value("select public.verify_shop_item($1)",[item.id]);
 await value("select public.confirm_pick_return_route($1)",[route]);
 assert.equal(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
});

let returnFixtureDays=210;
async function driverReturnFixture(suffix:string){
 const {job,token}=await readyReturn(suffix);
 returnFixtureDays+=7;const day=await value<string>("select ((now() at time zone 'America/Denver')::date+$1::integer)::text",[returnFixtureDays]);
 const a=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[job,day,token]);
 const stop=await value<string>("select public.route_schedule($1,'Return',$2,$3,$4)",[job,a.day,a.slots[0].eta,token]);
 await db.query("update public.pick_return_orders set delivery_payment_method='Cash' where job_id=$1",[job]);
 const route=await value<string>("select route_id from public.pick_return_stops where id=$1",[stop]);
 const items=await db.query<{id:string}>("select id from public.job_items where job_id=$1",[job]);
 await value("select public.verify_route_items($1,'Loaded',$2::uuid[])",[stop,items.rows.map(i=>i.id)]);
 await value("select public.depart_driver_route($1)",[route]);
 return {job,token,stop};
}

test("Return arrival waits five minutes, customer response cancels timer, and attended Cash delivery creates acknowledgment only after handover",async()=>{
 const {job,stop}=await driverReturnFixture("return-driver-attended");
 await value("select public.return_driver_action($1,'en-route')",[stop]);
 await value("select public.return_driver_action($1,'arrived')",[stop]);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",['return-arrived:'+stop])),1);
 await assert.rejects(value("select public.return_driver_action($1,'not-home')",[stop]),/five minutes/);
 assert.equal(await value("select public.return_acknowledgment_link($1)",[stop]),null);
 await value("select public.return_driver_action($1,'customer-coming')",[stop]);
 assert.equal(await value("select return_wait_until is null from public.pick_return_stops where id=$1",[stop]),true);
 await assert.rejects(value("select public.return_driver_action($1,'not-home')",[stop]),/five minutes/);
 await assert.rejects(value("select public.return_driver_action($1,'delivered',false)",[stop]),/customer must be present/);
 await assert.rejects(value("select public.return_driver_action($1,'cash',false)",[stop]),/customer must be present/);
 await value("select public.return_driver_action($1,'cash',true)",[stop]);
 await assert.rejects(value("select public.return_driver_action($1,'delivered',true)",[stop]),/delivery photos/);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Delivery Evidence','return-test.jpg',$2,$3,'Available')",[unit,job,stop]);
 await value("select public.return_driver_action($1,'delivered',true)",[stop]);
 const completion=await value<string>("select public.return_acknowledgment_link($1)",[stop]);assert.ok(completion);
 const paidBefore=await value<number>("select collected from public.job_commercial_totals where id=$1",[job]);
 await value("select public.public_completion($1,'accept')",[completion]);
 assert.equal(await value("select collected from public.job_commercial_totals where id=$1",[job]),paidBefore);
});

test("Return pending extension and production hold block handover; additional work closes one hour before the window",async()=>{
 const {job,stop}=await driverReturnFixture("return-driver-addition");
 const key='80000000-0000-0000-0000-000000000097';
 const extension=await value<string>("select public.request_job_extension($1,'Add a mark',$2)",[job,key]);
 await assert.rejects(value("select public.return_driver_action($1,'en-route')",[stop]),/additional work/);
 await db.query("update public.job_extensions set status='Cancelled' where id=$1",[extension]);
 await db.query("update public.jobs set work_stage='Cancellation Requested / Production Hold' where id=$1",[job]);
 await assert.rejects(value("select public.return_driver_action($1,'delivered',true)",[stop]),/Production Hold/);
 await db.query("update public.jobs set work_stage='Delivery In Progress' where id=$1",[job]);
 await db.query("update public.pick_return_stops set window_start=now()+interval '30 minutes',window_end=now()+interval '4 hours' where id=$1",[stop]);
 await assert.rejects(value("select public.request_job_extension($1,'Too late',$2)",[job,'80000000-0000-0000-0000-000000000098']),/one hour/);
});

 test("Unpaid provisional Return expires after fifteen days and releases route capacity",async()=>{
 const {job}=await readyReturn("retry-expiry");
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 await db.query("update public.pick_return_orders set return_reservation_expires_at=now()-interval '1 second' where job_id=$1",[job]);
 await value("select private.reconcile_delivery($1)",[job]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Shop Pickup");
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[job])),0);
 assert.equal(await value("select return_reservation_stop_id from public.pick_return_orders where job_id=$1",[job]),null);
 });

test("Unpaid retry is released at the route cutoff and its uncollected fee is voided",async()=>{
 const {job,token}=await readyReturn("retry-cutoff");
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);
 await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 await value("select public.choose_second_return($1,$2)",[job,token]);
 await db.query("update public.pick_return_stops set window_start=now()+interval '30 minutes' where id=(select return_reservation_stop_id from public.pick_return_orders where job_id=$1)",[job]);
 await value("select private.reconcile_delivery($1)",[job]);
 assert.equal(await value("select delivery_payment_status from public.pick_return_orders where job_id=$1",[job]),"Shop Pickup");
 assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[job])),0);
 assert.equal(await value("select b.transaction_status from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=$1",[job]),"Voided");
});

test("Explicit route departure notifies confirmed customers once and rejects unknown routes",async()=>{
 const {job,token}=await readyReturn("departure");
 const availability=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',((now() at time zone 'America/Denver')::date+1500),$2)",[job,token]);
 await value("select public.route_schedule($1,'Return',$2,$3,$4)",[job,availability.day,availability.slots[0].eta,token]);
 const route=await value<string>("select s.route_id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await assert.rejects(value("select public.depart_driver_route($1)",[route]),/Verify all items/);
 const checks=await value<{stop:string;items:{id:string}[]}[]>("select public.route_item_checklist($1,'Loaded')",[route]);
 for(const row of checks){await value("select public.verify_route_items($1,'Loaded',$2::uuid[])",[row.stop,row.items.map(i=>i.id)]);await db.query("update public.pick_return_orders set delivery_payment_method='Cash' where job_id=(select job_id from public.pick_return_stops where id=$1)",[row.stop]);}
 await value("select public.depart_driver_route($1)",[route]);
 const count=Number(await value("select count(*) from public.notifications where dedupe_key like $1",['route-departed:'+route+':%']));
 assert.ok(count>0);
 await value("select public.depart_driver_route($1)",[route]);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key like $1",['route-departed:'+route+':%'])),count);
 assert.ok(await value("select departed_at from public.pick_return_routes where id=$1",[route]));
 await assert.rejects(value("select public.depart_driver_route(gen_random_uuid())"),/unavailable|not assigned/);
});

for(const leg of ["Pickup","Return"]){
 test(`${leg} completion leaving three stops notifies exactly those customers once and updates approximate ETA without replay`,async()=>{
 const route=await value<string>("insert into public.pick_return_routes(unit_id,route_date,leg) values($1,((now() at time zone 'America/Denver')::date+500),$2) returning id",[unit,leg]);
 const stops:string[]=[];
 for(let i=0;i<4;i++){
 const {job}=leg==="Pickup"?await driverPickupFixture(`nearby-${leg}-${i}`):await readyReturn(`nearby-${leg}-${i}`);
 stops.push(await value<string>("insert into public.pick_return_stops(unit_id,route_id,job_id,sequence,status,address) values($1,$2,$3,$4,'Scheduled','101 Test Street') returning id",[unit,route,job,i+1]));
 }
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stops[0]]);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) select unit_id,'Receiving Evidence','nearby-test.jpg',job_id,id,'Available' from public.pick_return_stops where route_id=$1",[route]);
 await db.query("update public.pick_return_stops set status='Completed',customer_present_at=now() where id=$1",[stops[0]]);
 const notifications=await db.query<{dedupe_key:string}>("select dedupe_key from public.notifications where dedupe_key like $1",[`route-nearby:${route}:%`]);
 assert.equal(notifications.rows.length,3);assert.ok(!notifications.rows.some(n=>n.dedupe_key.endsWith(stops[0])));
 const estimates=stops.slice(1).map((id,i)=>({id,minutes:15*(i+1),latitude:40,longitude:-111}));
 await value("select public.update_driver_route_estimates($1,$2::jsonb)",[route,JSON.stringify(estimates)]);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key like $1 and payload->>'text' like '%ETA aprox.:%'",[`route-nearby:${route}:%`])),3);
 await db.query("update public.notifications set status='Sent' where dedupe_key like $1",[`route-nearby:${route}:%`]);
 const sent=await value<string>("select payload->>'text' from public.notifications where dedupe_key=$1",[`route-nearby:${route}:${stops[1]}`]);
 await value("select public.update_driver_route_estimates($1,$2::jsonb)",[route,JSON.stringify(estimates.map(e=>({...e,minutes:e.minutes+10})))]);
 assert.equal(await value("select payload->>'text' from public.notifications where dedupe_key=$1",[`route-nearby:${route}:${stops[1]}`]),sent);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stops[1]]);
 await db.query("update public.pick_return_stops set status='Completed',customer_present_at=now() where id=$1",[stops[1]]);
 assert.equal(await value("select approximate_eta from public.pick_return_stops where id=$1",[stops[1]]),null);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key like $1",[`route-nearby:${route}:%`])),3);
 await value("select public.update_driver_route_estimates($1,$2::jsonb)",[route,JSON.stringify([{id:stops[2],minutes:null}])]);
 assert.equal(await value("select approximate_eta from public.pick_return_stops where id=$1",[stops[2]]),null);
 await db.query("select set_config('request.jwt.claim.sub','',false)");
 try{await assert.rejects(value("select public.driver_route_estimate_context($1)",[route]));await assert.rejects(value("select public.update_driver_route_estimates($1,'[]'::jsonb)",[route]));}finally{await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[admin]);}
 });
}

let incidentDay=0;
async function freshIncidentRoute(f:{job:string;token:string;stop:string},leg:string){
 const day=await value<string>("select ((now() at time zone 'America/Denver')::date+$1::integer)::text",[700+7*incidentDay++]);
 const available=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,$2,$3,$4)",[f.job,leg,day,f.token]);
 f.stop=await value<string>("select public.route_schedule($1,$2,$3,$4,$5)",[f.job,leg,available.day,available.slots[0].eta,f.token]);
 return value<string>("select route_id from public.pick_return_stops where id=$1",[f.stop]);
}
async function incidentFixture(leg:string,suffix:string){
 const f=leg==='Pickup'?await driverPickupFixture(suffix):await driverReturnFixture(suffix);
 const route=await freshIncidentRoute(f,leg);
 const incident=await value<string>('select public.report_driver_incident($1)',[route]);return {...f,route,incident};
}
test('Pickup driver breakdown pauses the route, timeout reschedules next Saturday free with a $10 refund due',async()=>{
 const f=await incidentFixture('Pickup','incident-pickup');
 await assert.rejects(value("select public.pickup_driver_action($1,'en-route')",[f.stop]),/paused/);
 assert.equal(await value('select public.report_driver_incident($1)',[f.route]),f.incident);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",[`route-incident:${f.incident}:${f.job}`])),1);
 await db.query("update public.route_incidents set deadline=now()-interval '1 second' where id=$1",[f.incident]);
 await db.query("select set_config('request.jwt.claim.sub','',false),set_config('request.jwt.claim.role','service_role',false)");
 try{await value('select private.reconcile_driver_exceptions()');}finally{await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false),set_config('request.jwt.claim.role','authenticated',false)",[admin]);}
 assert.equal(await value('select status from public.route_incidents where id=$1',[f.incident]),'Rescheduled');
 assert.equal(await value('select status from public.pick_return_stops where id=$1',[f.stop]),'Cancelled');
 assert.equal(Number(await value('select amount from public.route_compensations where incident_id=$1 and job_id=$2',[f.incident,f.job])),10);
 assert.equal(Number(await value("select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Pickup' and r.route_date>(select route_date from public.pick_return_routes where id=$2) and s.status='Scheduled'",[f.job,f.route])),1);
 assert.notEqual(await value('select delivery_payment_status from public.pick_return_orders where job_id=$1',[f.job]),'Shop Pickup');
 await value('select public.resolve_driver_incident($1,$2)',[f.incident,'Continued']);
 assert.equal(await value('select status from public.route_incidents where id=$1',[f.incident]),'Rescheduled');
});
test('No replacement Return offers free shop pickup without counting a customer miss or creating a retry fee',async()=>{
 const f=await incidentFixture('Return','incident-return-shop');
 const before=Number(await value('select delivery_attempts from public.pick_return_orders where job_id=$1',[f.job]));
 await value('select public.resolve_driver_incident($1,$2)',[f.incident,'NoDriver']);
 assert.equal(await value('select delivery_payment_status from public.pick_return_orders where job_id=$1',[f.job]),'Shop Pickup');
 assert.equal(Number(await value('select delivery_attempts from public.pick_return_orders where job_id=$1',[f.job])),before);
 assert.equal(Number(await value('select count(*) from public.delivery_attempt_fees where job_id=$1',[f.job])),0);
 assert.equal(Number(await value('select amount from public.route_compensations where incident_id=$1 and job_id=$2',[f.incident,f.job])),10);
});
test('Replacement continues with $5 compensation; customer may reschedule and upgrade total to $10, never duplicate',async()=>{
 const f=await incidentFixture('Return','incident-replacement');
 await value('select public.resolve_driver_incident($1,$2)',[f.incident,'Continued']);
 assert.equal(Number(await value('select amount from public.route_compensations where incident_id=$1 and job_id=$2',[f.incident,f.job])),5);
 await assert.rejects(value('select public.driver_incident_choice($1,$2,$3)',[f.job,'foreign','Reschedule']),/denied|unavailable/i);
 await value('select public.driver_incident_choice($1,$2,$3)',[f.job,f.token,'Reschedule']);
 await value('select public.driver_incident_choice($1,$2,$3)',[f.job,f.token,'Reschedule']);
 assert.equal(Number(await value('select amount from public.route_compensations where incident_id=$1 and job_id=$2',[f.incident,f.job])),10);
 assert.equal(Number(await value('select count(*) from public.route_compensations where incident_id=$1 and job_id=$2',[f.incident,f.job])),1);
});

async function manualRefundProof(job:string,request:string){
 return value<string>("insert into public.documents(unit_id,job_id,refund_request_id,type,file_name,status,storage_status,uploaded_by) values($1,$2,$3,'Refund Review Evidence','test-proof.png','Available','stored',$4) returning id",[unit,job,request,admin]);
}
async function confirmRefundWindow(id:string){
 await rpc('refund_request_action',{id,action:'confirm',reviewed:true});
 // Advance the fixture's confirmed dates rather than changing the system clock.
 await db.query("update public.refund_requests set confirmed_at=now()-interval '10 days',process_not_before=current_date-2,process_due=current_date where id=$1",[id]);
}
test('Manual route refunds require proof/reference, never use Cash and complete idempotently',async()=>{
 const f=await driverReturnFixture('incident-manual-refund');
 const due=await value<number>('select balance_due from public.job_commercial_totals where id=$1',[f.job]);
 const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,f.job,due]);
 await value('select public.confirm_payment_request($1)',[payment]);
 const route=await freshIncidentRoute(f,'Return');const incident=await value<string>('select public.report_driver_incident($1)',[route]);
 await value('select public.resolve_driver_incident($1,$2)',[incident,'Continued']);
 const id=await value<string>("select id from public.refund_requests where job_id=$1 and source_kind='Route'",[f.job]);
 assert.equal(Number(await value('select amount from public.refund_requests where id=$1',[id])),5);
 await assert.rejects(value('select public.confirm_route_refund($1,$2)',[await value('select source_id from public.refund_requests where id=$1',[id]),'REF']),/Finance/);
 await rpc('refund_request_action',{id,action:'confirm',reviewed:true});
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Zelle',reference:'REF'}),/business days/);
 await confirmRefundWindow(id);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Cash',reference:'REF'}),/Cash/);
 const account=await value<string>('select t.account_id from public.transactions t join public.collections c on c.transaction_id=t.id join public.sales s on s.transaction_id=c.sale_id where s.job_id=$1 limit 1',[f.job]);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Zelle',account_id:account,reference:'REF'}),/proof/);
 const proof=await manualRefundProof(f.job,id);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Zelle',account_id:account,proof_id:proof}),/reference/);
 const payload={id,action:'complete',account_id:await value('select t.account_id from public.transactions t join public.collections c on c.transaction_id=t.id join public.sales s on s.transaction_id=c.sale_id where s.job_id=$1 limit 1',[f.job]),method:'Zelle',proof_id:proof,reference:'ZELLE-REFUND-TEST'};
 await rpc('refund_request_action',payload);await rpc('refund_request_action',payload);
 assert.equal(Number(await value("select count(*) from public.transactions where reference='ZELLE-REFUND-TEST' and type='REFUND'")),1);
 assert.equal(await value('select status from public.refund_requests where id=$1',[id]),'Completed');
 const snapshot=await value<{job_code:string;method:string;amount:number}>('select confirmation_snapshot from public.refund_requests where id=$1',[id]);assert.equal(Number(snapshot.amount),5);assert.equal(snapshot.method,'Zelle');assert.ok(snapshot.job_code);
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key like $1",['manual-refund-completed:'+id+':%'])),1);
});
test('Card driver-down creates pending obligations immediately; worker transfers nothing and upgrade remains single',async()=>{
 const f=await driverReturnFixture('incident-card-refund');
 const due=await value<number>('select balance_due from public.job_commercial_totals where id=$1',[f.job]);
 const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,f.job,due]);await value('select public.confirm_payment_request($1)',[payment]);
 await db.query("update public.transactions set payment_method='Card',reference='STRIPE:cs_refund_test' where id in (select c.transaction_id from public.collections c join public.sales s on s.transaction_id=c.sale_id where s.job_id=$1)",[f.job]);
 const route=await freshIncidentRoute(f,'Return');await value('select public.report_driver_incident($1)',[route]);
 await value('select public.driver_incident_choice($1,$2,$3)',[f.job,f.token,'Wait']);
 const id=await value<string>("select id from public.refund_requests where job_id=$1 and source_kind='Route'",[f.job]);assert.equal(Number(await value('select amount from public.refund_requests where id=$1',[id])),5);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");try{assert.deepEqual(await value('select public.claim_route_refunds()'),[]);}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 await value('select public.driver_incident_choice($1,$2,$3)',[f.job,f.token,'Reschedule']);
 assert.equal(Number(await value('select amount from public.refund_requests where id=$1',[id])),10);assert.equal(Number(await value('select processed_amount from public.refund_requests where id=$1',[id])),0);
 assert.equal(Number(await value("select count(*) from public.refund_requests where job_id=$1 and source_kind='Route'",[f.job])),1);
});


test("Configured delivery weekday drives next-route rescheduling without changing Pickup or old stops",async()=>{
 const f=await incidentFixture('Return','configured-weekday');
 const oldDay=await value<string>("select route_date::text from public.pick_return_routes where id=$1",[f.route]);
 assert.equal(new Date(oldDay+'T12:00:00Z').getUTCDay(),0);
 await value("select public.save_settings($1::jsonb)",[JSON.stringify({unit_id:unit,delivery_route_iso_weekday:1})]);
 try{
 const a=await value<{day:string;route_iso_weekday:number;slots:{label:string}[]}>("select public.route_availability($1,'Return',$2,$3)",[f.job,oldDay,f.token]);
 assert.equal(a.route_iso_weekday,1);assert.equal(new Date(a.day+'T12:00:00Z').getUTCDay(),1);
 assert.equal(a.slots[0].label,'2:00 PM');assert.equal(a.slots.at(-1)?.label,'6:00 PM');
 const pickup=await driverPickupFixture('configured-pickup');
 const pa=await value<{day:string;route_iso_weekday:number}>("select public.route_availability($1,'Pickup',$2,$3)",[pickup.job,a.day,pickup.token]);
 assert.equal(pa.route_iso_weekday,6);assert.equal(new Date(pa.day+'T12:00:00Z').getUTCDay(),6);
 await value("select public.resolve_driver_incident($1,'Rescheduled')",[f.incident]);
 const nextDay=await value<string>("select r.route_date::text from public.pick_return_routes r join public.pick_return_stops s on s.route_id=r.id where s.job_id=$1 and s.status='Scheduled'",[f.job]);
 assert.equal(new Date(nextDay+'T12:00:00Z').getUTCDay(),1);assert.ok(nextDay>oldDay);
 assert.equal(await value("select route_date::text from public.pick_return_routes where id=$1",[f.route]),oldDay);
 await assert.rejects(db.query("update public.unit_settings set delivery_route_iso_weekday=8 where unit_id=$1",[unit]),/check constraint/);
 }finally{await db.query("update public.unit_settings set delivery_route_iso_weekday=7 where unit_id=$1",[unit]);}
});


test("Multiple route days enable Pickup acceptance and both calendars; disabled/empty days are rejected",async()=>{
 const payload={unit_id:unit,pickup_route_iso_weekdays:[6,2,2],return_route_iso_weekdays:[7,3]};
 await value('select public.save_settings($1::jsonb)',[JSON.stringify(payload)]);
 try{
 assert.deepEqual(await value('select pickup_route_iso_weekdays from public.unit_settings where unit_id=$1',[unit]),[2,6]);
 const customer=await createCustomer('Multiple pickup days','multiple-days');
 const quote=await createQuote(customer.id);const token=await value<string>('select public.send_quote($1)',[quote]);
 const ctx=await value<{available_saturdays:{date:string}[]}>('select private.quote_logistics_context($1)',[quote]);
 assert.ok(ctx.available_saturdays.length>0);
 assert.ok(ctx.available_saturdays.every(d=>[2,6].includes(new Date(d.date+'T12:00:00Z').getUTCDay())));
 const tuesday=ctx.available_saturdays.find(d=>new Date(d.date+'T12:00:00Z').getUTCDay()===2)!.date;
 const disabled=new Date(tuesday+'T12:00:00Z');disabled.setUTCDate(disabled.getUTCDate()+1);
 await assert.rejects(acceptWithLogistics(token,{option_code:'pickup_only',pickup_address:'101 Multiple Days',saturday_date:disabled.toISOString().slice(0,10)}),/available Pickup date/);
 const accepted=await acceptWithLogistics(token,{option_code:'pickup_only',pickup_address:'101 Multiple Days',saturday_date:tuesday});
 const job=accepted.job_id;const status=await value<string>('select private.ensure_job_status_link($1)',[job]);
 const a=await value<{day:string;route_iso_weekdays:number[]}>('select public.route_availability($1,$2,$3,$4)',[job,'Pickup',tuesday,status]);
 assert.deepEqual(a.route_iso_weekdays,[2,6]);assert.ok([2,6].includes(new Date(a.day+'T12:00:00Z').getUTCDay()));
 const r=await value<{day:string;route_iso_weekdays:number[]}>('select public.route_availability($1,$2,$3,$4)',[job,'Return',tuesday,status]);
 assert.deepEqual(r.route_iso_weekdays,[3,7]);assert.equal(new Date(r.day+'T12:00:00Z').getUTCDay(),3);
 // Full configured day advances to the next enabled day, not a hardcoded week later.
 await db.query('update public.unit_settings set max_pickup_stops_per_saturday=1 where unit_id=$1',[unit]);
 const other=await createCustomer('Next configured day','next-configured-day');const oq=await createQuote(other.id);const ot=await value<string>('select public.send_quote($1)',[oq]);
 await assert.rejects(acceptWithLogistics(ot,{option_code:'pickup_only',pickup_address:'102 Multiple Days',saturday_date:tuesday}),/capacity/);
 await assert.rejects(value('select public.save_settings($1::jsonb)',[JSON.stringify({unit_id:unit,pickup_route_iso_weekdays:[]})]),/check constraint/);
 await assert.rejects(value('select public.save_settings($1::jsonb)',[JSON.stringify({unit_id:unit,return_route_iso_weekdays:[0,8]})]),/check constraint/);
 }finally{await value('select public.save_settings($1::jsonb)',[JSON.stringify({unit_id:unit,pickup_route_iso_weekdays:[6],return_route_iso_weekdays:[7],max_pickup_stops_per_saturday:10})]);}
});


test("Customer route snapshot hides other customers, preserves read-only behavior and rejects foreign tokens",async()=>{
 const f=await driverPickupFixture('customer-route-one');const route=await freshIncidentRoute(f,'Pickup');
 const day=await value<string>('select route_date::text from public.pick_return_routes where id=$1',[route]);
 const other=await driverPickupFixture('customer-route-two');
 const available=await value<{day:string;slots:{eta:string}[]}>('select public.route_availability($1,$2,$3,$4)',[other.job,'Pickup',day,other.token]);
 other.stop=await value<string>('select public.route_schedule($1,$2,$3,$4,$5)',[other.job,'Pickup',available.day,available.slots[0].eta,other.token]);
 const before=await value<string>('select count(*)::text from public.notifications');
 type Snapshot={leg:string;stops:{position:number;status:string;is_customer:boolean}[];total:number;resolved:number;estimated_eta:string|null;own_status:string;paused:boolean};
 const get=()=>value<Snapshot[]>('select public.customer_route_tracking($1,$2)',[f.job,f.token]);
 let data=await get();assert.equal(data.length,1);assert.equal(data[0].total,2);assert.equal(data[0].resolved,0);assert.equal(data[0].stops.filter(s=>s.is_customer).length,1);assert.equal(data[0].estimated_eta,null);
 assert.equal(await value('select count(*)::text from public.notifications'),before);
 const text=JSON.stringify(data);for(const secret of [f.job,other.job,other.token,'customer-route-two','101 Pickup Way','latitude','longitude','address','recipient']) assert.ok(!text.includes(secret),secret);
 await assert.rejects(value('select public.customer_route_tracking($1,$2)',[f.job,other.token]),/Status link unavailable/);
 // Anonymous caller needs the exact capability token even when staff membership is absent.
 await db.query("select set_config('request.jwt.claim.sub','',false),set_config('request.jwt.claim.role','anon',false)");
 try{assert.equal((await get())[0].total,2);await assert.rejects(value('select public.customer_route_tracking($1,$2)',[f.job,'wrong']),/Access denied/);}finally{await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false),set_config('request.jwt.claim.role','authenticated',false)",[admin]);}
 await value('select public.depart_driver_route($1)',[route]);
 await value('select public.update_driver_route_estimates($1,$2::jsonb)',[route,JSON.stringify([{id:f.stop,minutes:30},{id:other.stop,minutes:45}])]);
 data=await get();assert.ok(data[0].estimated_eta);
 await db.query("update public.pick_return_orders set route_eta_updated_at=now()-interval '11 minutes' where job_id=$1",[f.job]);assert.equal((await get())[0].estimated_eta,null);
 await value('select public.update_driver_route_estimates($1,$2::jsonb)',[route,JSON.stringify([{id:f.stop,minutes:30},{id:other.stop,minutes:45}])]);
 await value("select public.pickup_driver_action($1,'en-route')",[f.stop]);assert.equal((await get())[0].estimated_eta,null,'A stop change invalidates the old estimate');
 await value("select public.pickup_driver_action($1,'arrived')",[f.stop]);assert.equal((await get())[0].own_status,'Arrived');
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Receiving Evidence','tracking-test.jpg',$2,$3,'Available')",[unit,f.job,f.stop]);
 await value("select public.pickup_driver_action($1,'picked-up')",[f.stop]);data=await get();assert.equal(data[0].resolved,1);assert.equal(data[0].stops[1].status,'En Route');
 await value('select public.report_driver_incident($1)',[route]);assert.equal((await get())[0].paused,true);
});

test("Customer arrival response requires the exact status capability, cancels wait and broadcasts no customer data",async()=>{
 const f=await driverPickupFixture("audit-arrival",2500);await value("select public.pickup_driver_action($1,'en-route')",[f.stop]);await value("select public.pickup_driver_action($1,'arrived')",[f.stop]);
 await assert.rejects(value("select public.customer_arrival_response('wrong','Pickup')"),/Status link unavailable/);
 const channel=await value<string>("select public.status_live_channel($1)",[f.token]);assert.match(channel,/^tt-status:[a-f0-9]{64}$/);
 await value("select public.customer_arrival_response($1,'Pickup')",[f.token]);
 assert.equal(await value("select pickup_wait_until is null and customer_coming_at is not null from public.pick_return_stops where id=$1",[f.stop]),true);
 const arrival=await value<{leg:string;responded:boolean}>("select public.customer_arrival_context($1)",[f.token]);assert.deepEqual(arrival,{leg:"Pickup",responded:true});
 assert.ok(Number(await value("select count(*) from realtime.audit_test_events where topic=$1",[channel]))>0);
 assert.equal(Number(await value("select count(*) from realtime.audit_test_events where payload<>'{}'::jsonb")),0);
 await assert.rejects(value("select public.customer_delivery_acknowledge($1)",[f.token]),/Delivery has not occurred/);
 await assert.rejects(value("select public.report_driver_incident((select route_id from public.pick_return_stops where id=$1))",[f.stop]),/arrived stop/);
});

test("Shop receipt blocks both legacy production and item progression until each item is verified",async()=>{
 const f=await driverPickupFixture("audit-shop",2510);await value("select public.pickup_driver_action($1,'en-route')",[f.stop]);await value("select public.pickup_driver_action($1,'arrived')",[f.stop]);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Receiving Evidence','audit-received.jpg',$2,$3,'Available')",[unit,f.job,f.stop]);
 await value("select public.pickup_driver_action($1,'picked-up')",[f.stop]);
 assert.equal(await value("select work_stage from public.jobs where id=$1",[f.job]),"Received at Shop");
 const status=await value<{tracking_stage:string;steps:string[]}>("select public.public_job_status($1)",[f.token]);assert.equal(status.tracking_stage,"Received at Shop");assert.ok(status.steps.includes("Received at Shop"));
 const item=await value<string>("select id from public.job_items where job_id=$1 limit 1",[f.job]);
 await assert.rejects(value("select public.advance_job_item($1,'next')",[item]),/Shop must verify/);
 await assert.rejects(db.query("update public.jobs set work_stage='Preparing' where id=$1",[f.job]),/Shop must verify/);
 await value("select public.verify_shop_item($1)",[item]);await value("select public.verify_shop_item($1)",[item]);
 assert.equal(await value("select work_stage from public.jobs where id=$1",[f.job]),"Receiving Evidence");
 await value("select public.advance_job($1,'receiving-done')",[f.job]);assert.equal(await value("select work_stage from public.jobs where id=$1",[f.job]),"Preparing");
});

test("Return cannot leave with an electronic balance, and cash loading must be verified per item",async()=>{
 const f=await readyReturn("audit-load");const a=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Return',((now() at time zone 'America/Denver')::date+1800),$2)",[f.job,f.token]);
 const stop=await value<string>("select public.route_schedule($1,'Return',$2,$3,$4)",[f.job,a.day,a.slots[0].eta,f.token]);const route=await value<string>("select route_id from public.pick_return_stops where id=$1",[stop]);
 await assert.rejects(value("select public.return_driver_action($1,'en-route')",[stop]),/start the route/);
 await assert.rejects(value("select public.depart_driver_route($1)",[route]),/Verify all items/);
 const item=await value<string>("select id from public.job_items where job_id=$1 limit 1",[f.job]);
 await assert.rejects(value("select public.verify_route_items($1,'Loaded',array[gen_random_uuid()])",[stop]),/Invalid item list/);
 await value("select public.verify_route_items($1,'Loaded',array[$2::uuid])",[stop,item]);
 await db.query("update public.pick_return_orders set delivery_payment_method='Zelle' where job_id=$1",[f.job]);
 await assert.rejects(value("select public.depart_driver_route($1)",[route]),/Only cash deliveries/);
 await db.query("update public.pick_return_orders set delivery_payment_method='Cash' where job_id=$1",[f.job]);
 await value("select public.depart_driver_route($1)",[route]);await value("select public.return_driver_action($1,'en-route')",[stop]);
 await assert.rejects(db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Delivery Evidence','too-early.jpg',$2,$3,'Available')",[unit,f.job,stop]),/Arrive before/);
 await value("select public.return_driver_action($1,'arrived')",[stop]);await value("select public.customer_arrival_response($1,'Return')",[f.token]);
 assert.equal(await value("select return_wait_until is null and return_customer_coming_at is not null from public.pick_return_stops where id=$1",[stop]),true);
});

test("A failed Return keeps the route open until the shop verifies all returned physical items",async()=>{
 const f=await driverReturnFixture("audit-return-shop");const route=await value<string>("select route_id from public.pick_return_stops where id=$1",[f.stop]);
 await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);await db.query("update public.pick_return_stops set return_wait_until=now()-interval '1 second' where id=$1",[f.stop]);await value("select public.return_driver_action($1,'not-home')",[f.stop]);
 await assert.rejects(value("select public.confirm_pick_return_route($1)",[route]),/Return all undelivered items/);
 const checks=await value<{stop:string;items:{id:string}[]}[]>("select public.route_item_checklist($1,'Returned')",[route]);assert.equal(checks.length,1);
 await value("select public.verify_route_items($1,'Returned',$2::uuid[])",[f.stop,checks[0].items.map(i=>i.id)]);await value("select public.confirm_pick_return_route($1)",[route]);assert.equal(await value("select status from public.pick_return_routes where id=$1",[route]),"Completed");
});

test("Opt-in additional addresses belong to the customer and preserve original personal/company addresses",async()=>{
 const customer=await createCustomer("Audit addresses","audit-addresses");const quote=await createQuote(customer.id);const token=await value<string>("select public.send_quote($1)",[quote]);
 await value("select public.accept_review_with_logistics($1,true,true,$2::jsonb)",[token,JSON.stringify({option_code:"dropoff_delivery",delivery_address:"909 Saved Street, Draper UT",save_delivery_address:true})]);
 assert.equal(Number(await value("select count(*) from private.customer_extra_addresses where customer_id=$1",[customer.id])),1);
 assert.equal(await value("select address from public.customers where id=$1",[customer.id]),"101 Personal Way, Draper, UT 84020");
 const second=await createQuote(customer.id);const context=await value<{extra_addresses:string[]}>("select private.quote_logistics_context($1)",[second]);assert.deepEqual(context.extra_addresses,["909 Saved Street, Draper UT"]);
 await value("select public.accept_review_with_logistics($1,true,true,$2::jsonb)",[token,JSON.stringify({option_code:"dropoff_delivery",delivery_address:"909 Saved Street, Draper UT",save_delivery_address:true})]);assert.equal(Number(await value("select count(*) from private.customer_extra_addresses where customer_id=$1",[customer.id])),1);
});

test("Return availability and automatic assignment never precede a future pickup",async()=>{
 const f=await readyReturn("audit-return-date");const pickup=await value<string>("select ((now() at time zone 'America/Denver')::date+2200)::text");
 await db.query("update public.pick_return_orders set pickup_window_start=($2::date+time '08:00') at time zone 'America/Denver' where job_id=$1",[f.job,pickup]);
 const a=await value<{day:string}>("select public.route_availability($1,'Return',(now() at time zone 'America/Denver')::date,$2)",[f.job,f.token]);assert.ok(a.day>=pickup);
 const stop=await value<string>("select private.auto_return($1)",[f.job]);assert.ok(await value<boolean>("select (window_start at time zone 'America/Denver')::date >= $2::date from public.pick_return_stops where id=$1",[stop,pickup]));
});

test("Payment cutoff reminders are dated, idempotent and do not replay historical notifications",async()=>{
 const f=await readyReturn("audit-cutoff");const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[f.job]);
 await db.query("update public.pick_return_stops set window_start=now()+interval '47 hours',window_end=now()+interval '51 hours' where id=$1",[stop]);
 const old=Number(await value("select count(*) from public.notifications where event='QUOTE_SENT' and status='Sent'"));
 await value("select private.audit_cutoff_reminders()");await value("select private.audit_cutoff_reminders()");
 assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key like $1",['audit-cutoff:'+stop+':%'])),1);
 assert.match(await value<string>("select payload->>'text' from public.notifications where dedupe_key like $1",['audit-cutoff:'+stop+':%']),/Payment deadline:.*America\/Denver/);
 assert.equal(Number(await value("select count(*) from public.notifications where event='QUOTE_SENT' and status='Sent'")),old);
});

test("Controlled cash Return flow accepts receipt from the customer's status link only after paid attended handover",async()=>{
 const f=await driverReturnFixture("audit-complete-flow");
 await assert.rejects(value("select public.customer_delivery_acknowledge($1)",[f.token]),/Delivery has not occurred/);
 await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);
 await db.query("insert into public.documents(unit_id,type,file_name,job_id,pick_return_stop_id,status) values($1,'Delivery Evidence','audit-delivered.jpg',$2,$3,'Available')",[unit,f.job,f.stop]);
 await assert.rejects(value("select public.return_driver_action($1,'delivered',true)",[f.stop]),/Outstanding balance|Payment|Collect and confirm payment/);
 await value("select public.return_driver_action($1,'cash',true)",[f.stop]);
 assert.equal(Number(await value("select balance_due from public.job_commercial_totals where id=$1",[f.job])),0);
 await value("select public.return_driver_action($1,'delivered',true)",[f.stop]);
 await assert.rejects(value("select public.customer_delivery_acknowledge('foreign')"),/Status link unavailable/);
 await value("select public.customer_delivery_acknowledge($1)",[f.token]);await value("select public.customer_delivery_acknowledge($1)",[f.token]);
 assert.equal(Number(await value("select count(*) from public.delivery_acknowledgments where job_id=$1",[f.job])),1);
 assert.equal(await value("select status from public.jobs where id=$1",[f.job]),"Completed");
});

test("SMS explicit consent is capability-scoped and revocation stops queued messages", async () => {
 const customer = await createCustomer("SMS consent customer", "sms-consent");
 const quote = await createQuote(customer.id);
 const token = await value<string>("select public.send_quote($1)",[quote]);
 const phone = "+18015550123";
 await assert.rejects(value("select public.set_sms_consent('wrong','quote',$1,true)",[phone]),/unavailable/);
 await assert.rejects(value("select public.set_sms_consent($1,'quote','bad',true)",[token]),/mobile number/);
 assert.equal((await value<{granted:boolean}>("select public.sms_consent_state($1,'quote')",[token])).granted,false);
 await value("select public.set_sms_consent($1,'quote',$2,true)",[token,phone]);
 const state=await value<{phone:string;granted:boolean}>("select public.sms_consent_state($1,'quote')",[token]);assert.equal(state.granted,true);assert.equal(state.phone,phone);
 await db.query("update private.sms_settings set enabled=true,activated_at=now()-interval '1 second' where unit_id=$1",[unit]);
 const id=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'PAYMENT_DUE',$2,'sms-consent-pending','{\"text\":\"Payment cutoff tomorrow\"}') returning id",[unit,quote]);
 assert.equal(await value("select status from private.sms_deliveries where notification_id=$1",[id]),"Pending");
 await value("select public.set_sms_consent($1,'quote','',false)",[token]);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try { await value("select public.claim_sms()"); } finally {await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 assert.equal(await value("select reason from private.sms_deliveries where notification_id=$1",[id]),"NO_OPT_IN");
 await db.query("update private.sms_settings set enabled=false where unit_id=$1",[unit]);
});
test("SMS disabled activation never replays history and worker claims are one-shot", async () => {
 const customer=await createCustomer("SMS queue customer","sms-queue"),quote=await createQuote(customer.id);
 const token=await value<string>("select public.send_quote($1)",[quote]);await value("select public.set_sms_consent($1,'quote','+18015550124',true)",[token]);
 const old=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'PAYMENT_DUE',$2,'sms-disabled','{\"text\":\"Old cutoff\"}') returning id",[unit,quote]);
 assert.equal(await value("select reason from private.sms_deliveries where notification_id=$1",[old]),"DISABLED");
 await value("select public.save_sms_settings($1::jsonb,null)",[JSON.stringify({enabled:true,region:"us-west-2",origination_number:"+18015550101",test_phone:"+18015550102"})]);
 const id=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'PICKUP_ARRIVED',$2,'sms-new-arrival','{\"text\":\"Driver here\"}') returning id",[unit,quote]);
 await assert.rejects(value("select public.sms_runtime_config()"),/Worker credentials/);
 await assert.rejects(value("select public.claim_sms()"),/Worker credentials/);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  const claimed=await value<{id:string;claim:string}>("select public.claim_sms()");assert.equal(claimed.id,id);
  assert.equal(await value("select public.claim_sms()"),null);
  assert.equal(await value("select public.finish_sms($1,$2,'Unknown',null,'SNS_DELIVERY_UNKNOWN')",[id,claimed.claim]),true);
  assert.equal(await value("select public.claim_sms()"),null);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 assert.equal(await value("select status from private.sms_deliveries where notification_id=$1",[old]),"Skipped");
 await db.query("update private.sms_settings set enabled=false where unit_id=$1",[unit]);
});
test("SMS settings hide secrets and restrict administrative configuration", async () => {
 await db.query("update private.sms_settings set encrypted_credentials='fakeiv.faketag.fakecipher' where unit_id=$1",[unit]);
 const settings=await value<Record<string,unknown>>("select public.sms_settings_status()");assert.equal(settings.credentials_saved,true);assert.equal(settings.encrypted_credentials,undefined);
 await db.query("select set_config('request.jwt.claim.sub','',false)");
 try {await assert.rejects(value("select public.sms_settings_status()"),/Administrative|Permission denied|Owner/);await assert.rejects(value("select public.save_sms_settings('{}',null)"),/Administrative|Permission denied|Owner/);} finally {await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[admin]);}
});

test("Real customer email and US phone are unique across formats and updates", async () => {
 const first=await createCustomer("Unique real contact","unique-real-contact");
 const payload={unit_id:unit,name:"Another real contact",email:"other-unique@example.test",phone:`+1${first.phone}`,address:"Utah"};
 await assert.rejects(rpc("save_customer",payload),/phone number already belongs/);
 await assert.rejects(rpc("save_customer",{...payload,phone:"3855550999",email:" UNIQUE-REAL-CONTACT@EXAMPLE.TEST "}),/email already belongs/);
 const second=await rpc("save_customer",{...payload,phone:"3855550999"});
 await assert.rejects(rpc("save_customer",{...payload,id:second,phone:first.phone}),/phone number already belongs/);
 await assert.rejects(db.query("update public.customers set email='unique-real-contact@example.test' where id=$1",[second]),/email already belongs/);
 await rpc("save_customer",{...payload,id:second,phone:"3855550999"});
});
test("TEST customers stay distinct with shared phone/email and cannot become duplicate real contacts", async () => {
 const p={unit_id:unit,name:"TEST-Shared One",phone:"3852142163",email:"test-shared@example.test",address:"Utah"};
 const first=await rpc("save_customer",p),second=await rpc("save_customer",{...p,name:"TEST-Shared Two"});
 assert.notEqual(first,second);
 const real=await rpc("save_customer",{...p,name:"Real shared contact"});assert.notEqual(real,first);
 await assert.rejects(rpc("save_customer",{...p,id:first,name:"Former test now real"}),/email already belongs/);
});
test("TEST SMS alerts only queue for the configured shared test recipient", async () => {
 const customer=await createCustomer("TEST-SMS fixture","test-sms-fixture"),quote=await createQuote(customer.id);
 const token=await value<string>("select public.send_quote($1)",[quote]);
 await value("select public.set_sms_consent($1,'quote','+13852142163',true)",[token]);
 await db.query("update private.sms_settings set enabled=true,activated_at=now()-interval '1 second',test_phone='+13852142163' where unit_id=$1",[unit]);
 const id=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'PICKUP_ARRIVED',$2,'test-sms-allowed','{}') returning id",[unit,quote]);
 assert.equal(await value("select status from private.sms_deliveries where notification_id=$1",[id]),"Pending");
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {const c=await value<{phone:string;test_customer:boolean}>("select public.claim_sms()");assert.equal(c.phone,"+13852142163");assert.equal(c.test_customer,true);}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 await db.query("update private.sms_settings set test_phone='+18015550102' where unit_id=$1",[unit]);
 const blocked=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'RETURN_ARRIVED',$2,'test-sms-blocked','{}') returning id",[unit,quote]);
 assert.equal(await value("select reason from private.sms_deliveries where notification_id=$1",[blocked]),"TEST_RECIPIENT_MISMATCH");
 await db.query("update private.sms_settings set enabled=false where unit_id=$1",[unit]);
});

test("Phone codes require server access, delivery, matching session/phone and expire", async () => {
 const id="91000000-0000-0000-0000-000000000001",session="a".repeat(64),code="b".repeat(64),network="c".repeat(64),phone="+18015550801";
 await assert.rejects(value("select public.begin_phone_verification($1,$2,$3,$4,$5)",[id,phone,session,code,network]),/Server credentials/);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  await value("select public.begin_phone_verification($1,$2,$3,$4,$5)",[id,phone,session,code,network]);
  assert.equal(await value("select public.check_phone_verification($1,$2,$3)",[id,session,code]),false);
  await value("select public.phone_verification_result($1,'Sent')",[id]);
  assert.equal(await value("select public.check_phone_verification($1,$2,$3)",[id,"x".repeat(64),code]),false);
  assert.equal(await value("select public.check_phone_verification($1,$2,$3)",[id,session,code]),true);
  assert.equal(await value("select public.phone_verification_valid($1,$2,$3)",[id,session,phone]),true);
  assert.equal(await value("select public.phone_verification_valid($1,$2,'+18015550802')",[id,session]),false);
  await db.query("update private.phone_verifications set expires_at=now()-interval '1 second' where id=$1",[id]);
  assert.equal(await value("select public.phone_verification_valid($1,$2,$3)",[id,session,phone]),false);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
});
test("Phone verification caps code guesses and rate limits resends", async () => {
 const id="91000000-0000-0000-0000-000000000002",session="d".repeat(64),code="e".repeat(64),network="f".repeat(64),phone="+18015550803";
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  await value("select public.begin_phone_verification($1,$2,$3,$4,$5)",[id,phone,session,code,network]);
  await assert.rejects(value("select public.begin_phone_verification('91000000-0000-0000-0000-000000000003',$1,$2,$3,$4)",[phone,session,code,network]),/60 seconds/);
  await value("select public.phone_verification_result($1,'Sent')",[id]);
  for(let i=0;i<5;i++)assert.equal(await value("select public.check_phone_verification($1,$2,$3)",[id,session,"0".repeat(64)]),false);
  assert.equal(await value("select public.check_phone_verification($1,$2,$3)",[id,session,code]),false);
  assert.equal(await value("select attempts from private.phone_verifications where id=$1",[id]),5);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
});

test("Short SMS context uses original Quote link before Job and existing status link afterwards", async () => {
 const customer=await createCustomer("Short SMS context","short-sms-context"),quote=await createQuote(customer.id);
 const token=await value<string>("select public.send_quote($1)",[quote]);
 const notification=await value<string>("select id from public.notifications where entity_id=$1 and event='Quote Sent' order by created_at desc limit 1",[quote]);
 await assert.rejects(value("select public.sms_message_context($1)",[notification]),/Worker credentials/);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  const ctx=await value<{job_code:string;action_path:string}>("select public.sms_message_context($1)",[notification]);
  assert.equal(ctx.action_path,"/review/"+token);assert.match(ctx.job_code,/TT-Q-/);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 const accepted=await acceptWithLogistics(token,{option_code:"dropoff_pickup"});
 const job=accepted.job_id;
 const oldToken=await value<string>("select private.ensure_job_status_link($1)",[job]);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  const ctx=await value<{job_code:string;action_path:string}>("select public.sms_message_context($1)",[notification]);
  assert.equal(ctx.action_path,"/status/"+oldToken);assert.match(ctx.job_code,/TT-J-/);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 assert.equal(await value("select token from private.job_status_links where job_id=$1",[job]),oldToken);
 assert.equal(await value("select token from private.quote_delivery where quote_id=$1",[quote]),token);
});

test("Stripe TEST worker lookup does not expose tables or accept real customers", async () => {
 const real=await createCustomer("Real Stripe guard","real-stripe-guard"),q=await createQuote(real.id);
 const token=await value<string>("select public.send_quote($1)",[q]);const accepted=await acceptWithLogistics(token,{option_code:"dropoff_pickup"});
 await assert.rejects(value("select public.stripe_test_customer($1)",[accepted.job_id]),/Worker credentials/);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try {
  assert.equal(await value("select public.stripe_test_customer($1)",[accepted.job_id]),false);
  await assert.rejects(value("select private.stripe_payment_account($1,$2,'cs_test_guard')",[unit,accepted.job_id]),/TEST- customer/);
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
});

async function staffAs(user: string, action: () => Promise<void>) {
 await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[user]);
 await db.exec("set row_security=on;set role authenticated");
 try {await action();} finally {await db.exec("reset role");await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[admin]);}
}
async function addStaff(roleKeys: string[], name: string) {
 const user=await value<string>("insert into auth.users(id,email) values(gen_random_uuid(),$1) returning id",[`${name}@example.test`]);
 const roles=(await db.query<{id:string}>("select id from public.roles where unit_id=$1 and system_key=any($2::text[])",[unit,roleKeys])).rows.map(r=>r.id);
 await value("select public.rbac_save_user($1,$2,true,$3::uuid[])",[user,name,roles]);return user;
}
test("RBAC bootstraps Owner, permits role unions/future blocks and guards last active Owner",async()=>{
 const access=await value<{owner:boolean;blocks:string[]}>("select public.staff_permissions()");assert.equal(access.owner,true);assert.equal(access.blocks.length,18);
 await db.query("insert into public.permission_blocks values('future.test','Future test','System')");
 assert.equal(await value<boolean>("select private.has_block($1,'future.test')",[unit]),true);
 const employee=await addStaff(['Employee'],'rbac-employee');
 await staffAs(employee,async()=>{
 const a=await value<{owner:boolean;blocks:string[]}>("select public.staff_permissions()");assert.equal(a.owner,false);assert.ok(a.blocks.includes('production.work'));assert.ok(!a.blocks.includes('quotes.manage'));
 await assert.rejects(value("select public.rbac_directory()"),/Owner/);
 await assert.rejects(value("select public.rbac_save_role(null,'Escalate',array['users.manage'])"),/Owner/);
 await assert.rejects(value("select public.save_settings($1::jsonb)",[JSON.stringify({unit_id:unit})]),/Permission denied|Owner/);
 await assert.rejects(value("select public.record_movement($1::jsonb)",[JSON.stringify({unit_id:unit,type:'OWNER_DRAW',amount:1})]),/Permission denied/);
 });
 const extra=await value<string>("select public.rbac_save_role(null,'TEST Quote Editor',array['quotes.manage'])");
 const employeeRole=await value<string>("select id from public.roles where unit_id=$1 and system_key='Employee'",[unit]);
 await value("select public.rbac_save_user($1,'Employee plus quotes',true,$2::uuid[])",[employee,[employeeRole,extra]]);
 await staffAs(employee,async()=>{
 const a=await value<{blocks:string[]}>("select public.staff_permissions()");assert.ok(a.blocks.includes('quotes.manage'));assert.ok(a.blocks.includes('jobs.manage'));
 // A direct RPC, not just UI, now permits creating a Quote.
 const customer=await value<string>("select id from public.customers where unit_id=$1 limit 1",[unit]);
 await createQuote(customer);
 });
 await assert.rejects(value("select public.rbac_save_user($1,'Owner',false,'{}')",[admin]),/at least one active Owner/);
 const ownerRole=await value<string>("select id from public.roles where unit_id=$1 and system_key='Owner'",[unit]);
 await assert.rejects(value("select public.rbac_save_role($1,'Owner renamed','{}')",[ownerRole]),/immutable/);
 assert.ok(Number(await value("select count(*) from public.audit_log where actor_id=$1 and entity='rbac'",[admin]))>0);
 await db.query("delete from public.permission_blocks where key='future.test'");
});
test("RBAC Driver routes are assigned-only in RLS/RPC, cash remains scoped and foreign evidence is rejected",async()=>{
 const driver=await addStaff(['Driver'],'rbac-driver');const other=await addStaff(['Driver'],'rbac-other-driver');
 const own=await readyReturn('rbac-own'),foreign=await readyReturn('rbac-foreign');
 await value("select public.prepare_route_payment($1,'Cash',gen_random_uuid())",[own.token]);
 const ownRoute=await value<string>("insert into public.pick_return_routes(unit_id,route_date,leg) values($1,current_date+400,'Return') returning id",[unit]);
 const foreignRoute=await value<string>("insert into public.pick_return_routes(unit_id,route_date,leg) values($1,current_date+401,'Return') returning id",[unit]);
 await value("select public.assign_route_operator($1,$2)",[ownRoute,driver]);await value("select public.assign_route_operator($1,$2)",[foreignRoute,other]);
 const ownIncident=await value<string>("insert into public.route_incidents(unit_id,route_id,status) values($1,$2,'Continued') returning id",[unit,ownRoute]);
 const foreignIncident=await value<string>("insert into public.route_incidents(unit_id,route_id,status) values($1,$2,'Continued') returning id",[unit,foreignRoute]);
 const ownStop=await value<string>("insert into public.pick_return_stops(unit_id,route_id,job_id,sequence,status) values($1,$2,$3,1,'Arrived') returning id",[unit,ownRoute,own.job]);
 const foreignStop=await value<string>("insert into public.pick_return_stops(unit_id,route_id,job_id,sequence,status) values($1,$2,$3,1,'Arrived') returning id",[unit,foreignRoute,foreign.job]);
 await staffAs(driver,async()=>{
 assert.equal(Number(await value("select count(*) from public.pick_return_routes where id=$1",[ownRoute])),1);
 assert.equal(Number(await value("select count(*) from public.pick_return_routes where id=$1",[foreignRoute])),0);
 assert.equal(Number(await value("select count(*) from public.route_incidents where id=$1",[ownIncident])),1);
 assert.equal(Number(await value("select count(*) from public.route_incidents where id=$1",[foreignIncident])),0);
 assert.equal(Number(await value("select count(*) from public.jobs where id=$1",[foreign.job])),0);
 assert.equal(Number(await value("select count(*) from public.transactions where unit_id=$1",[unit])),0);
 const balances=await value<{id:string;balance_due:number}[]>("select public.driver_route_balances($1)",[ownRoute]);assert.ok(Number(balances.find(b=>b.id===own.job)?.balance_due)>0);
 await assert.rejects(value("select public.driver_route_balances($1)",[foreignRoute]),/not assigned/);
 await assert.rejects(value("select public.route_live_channel($1)",[foreignRoute]),/not assigned/);
 await assert.rejects(value("select public.return_driver_action($1,'customer-coming',false)",[foreignStop]),/not assigned/);
 await assert.rejects(value("select public.assign_route_operator($1,$2)",[ownRoute,other]),/planning permission/);
 await assert.rejects(value("select public.verify_route_items($1,'Returned',array[gen_random_uuid()])",[ownStop]),/Shop Return/);
 await assert.rejects(value("select public.register_document_metadata($1::jsonb)",[JSON.stringify({unit_id:unit,job_id:foreign.job,pick_return_stop_id:foreignStop,type:'Delivery Evidence',file_name:'test.jpg'})]),/not assigned/);
 await assert.rejects(value("select public.register_document_metadata($1::jsonb)",[JSON.stringify({unit_id:unit,job_id:own.job,pick_return_stop_id:ownStop,type:'Production Evidence',file_name:'test.jpg'})]),/Evidence permission/);
 const photo=await value<string>("select public.register_document_metadata($1::jsonb)",[JSON.stringify({unit_id:unit,job_id:own.job,pick_return_stop_id:ownStop,type:'Delivery Evidence',file_name:'rbac-photo.jpg',original_file_name:'rbac-photo.jpg',mime_type:'image/jpeg',file_size:1,sha256:'e'.repeat(64),visibility:'customer'})]);
 const photoPath=`${unit}/documents/${photo}/rbac-photo.jpg`;
 await assert.rejects(value("select public.finish_document_storage($1,'tooltag-files',$2,'stored',null)",[photo,photoPath]),/must be stored/);
 await db.query("insert into storage.objects(bucket_id,name) values('tooltag-files',$1)",[photoPath]);
 await db.query("update storage.objects set name=name where name=$1",[photoPath]);
 await value("select public.finish_document_storage($1,'tooltag-files',$2,'stored',null)",[photo,photoPath]);
 assert.equal(Number(await value("select count(*) from storage.objects where name=$1",[photoPath])),1);
 await assert.rejects(db.query("insert into storage.objects(bucket_id,name) values('tooltag-files',$1)",[`${unit}/documents/${foreign.job}/forged.jpg`]),/row-level security/);
 await assert.rejects(value("select public.return_acknowledgment_link($1)",[ownStop]),/Permission denied/);
 // Uses the existing cash confirmation chain; cannot confirm arbitrary payment requests.
 await value("select public.collect_route_cash($1)",[ownStop]);
 await value("select public.collect_route_cash($1)",[ownStop]);
 const delivered=await value<{completion_token:string|null}>("select public.return_driver_action($1,'delivered',true)",[ownStop]);assert.equal(delivered.completion_token,null);
 });
 assert.equal(Number(await value("select balance_due from public.job_commercial_totals where id=$1",[own.job])),0);
 assert.equal(Number(await value("select count(*) from public.payment_requests where request_key=$1",[ownStop])),1);
 const request=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',1,'Final Balance') returning id",[unit,foreign.job]);
 await staffAs(driver,async()=>{await assert.rejects(value("select public.confirm_payment_request($1)",[request]),/Only cash/);});
 const role=await value<string>("select id from public.roles where unit_id=$1 and system_key='Driver'",[unit]);
 await value("select public.rbac_save_user($1,'disabled driver',false,array[$2::uuid])",[driver,role]);
 await staffAs(driver,async()=>{
 const a=await value<{active:boolean;blocks:string[]}>("select public.staff_permissions()");assert.equal(a.active,false);assert.deepEqual(a.blocks,[]);
 assert.equal(Number(await value("select count(*) from public.pick_return_routes where id=$1",[ownRoute])),0);
 await assert.rejects(value("select public.route_live_channel($1)",[ownRoute]),/not assigned/);
 });
});
test("RBAC Employee payment recording works; ToolTag roles do not grant BOFT access",async()=>{
 const employee=await addStaff(['Employee'],'rbac-record-payment');const ready=await readyReturn('rbac-payment');
 const due=await value<number>("select balance_due from public.job_commercial_totals where id=$1",[ready.job]);
 const request=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,ready.job,due]);
 const boft=await value<string>("select id from public.business_units where id<>$1 limit 1",[unit]);
 await staffAs(employee,async()=>{
 await value("select public.confirm_payment_request($1)",[request]);
 await assert.rejects(value("select public.create_quote($1::jsonb)",[JSON.stringify({unit_id:unit})]),/Permission denied/);
 await assert.rejects(value("select public.save_settings($1::jsonb)",[JSON.stringify({unit_id:boft})]),/Administrative/);
 assert.equal(Number(await value("select count(*) from public.customers where unit_id=$1",[boft])),0);
 });
 assert.equal(Number(await value("select balance_due from public.job_commercial_totals where id=$1",[ready.job])),0);
 // Legacy BOFT Owner still works; no BOFT memberships or authorization rules were migrated.
 assert.equal(await value<boolean>("select private.can_access($1)",[boft]),true);
 await value("select private.require_admin($1)",[boft]);
 await value("select public.dashboard_stats($1)",[boft]);
 await value("select public.search_records($1,'TT')",[boft]);
});
test("RBAC catalog and administration expose no anonymous execute or direct write grants",async()=>{
 for(const name of ['public.rbac_directory()','public.rbac_save_role(uuid,text,text[])','public.rbac_save_user(uuid,text,boolean,uuid[])','public.assign_route_operator(uuid,uuid)','public.driver_route_balances(uuid)']) {
  assert.equal(await value<boolean>("select has_function_privilege('anon',$1,'EXECUTE')",[name]),false);
 }
 for(const table of ['roles','role_blocks','user_roles','staff_access','permission_blocks']) {
  assert.equal(await value<boolean>("select relrowsecurity from pg_class where oid=$1::regclass",[`public.${table}`]),true);
  assert.equal(await value<boolean>("select has_table_privilege('authenticated',$1,'INSERT')",[`public.${table}`]),false);
  assert.equal(await value<boolean>("select has_table_privilege('authenticated',$1,'UPDATE')",[`public.${table}`]),false);
 }
 const limitedRole=await value<string>("select public.rbac_save_role(null,'TEST Job Reader',array['jobs.view'])");
 const limitedUser=await value<string>("insert into auth.users values(gen_random_uuid(),'job-reader@example.test') returning id");
 await value("select public.rbac_save_user($1,'Job Reader',true,array[$2::uuid])",[limitedUser,limitedRole]);
 const receipt=await value<string>("insert into public.documents(unit_id,type,file_name) values($1,'Receipt','private-receipt.pdf') returning id",[unit]);
 await staffAs(limitedUser,async()=>{
  assert.equal(Number(await value("select count(*) from public.documents where id=$1",[receipt])),0);
  assert.equal(Number(await value("select count(*) from public.audit_log where entity='rbac'")),0);
 });
 const role=await value<string>("select public.rbac_save_role(null,'TEST delegated settings',array['settings.manage','users.manage'])");
 const user=await value<string>("insert into auth.users values(gen_random_uuid(),'delegated-settings@example.test') returning id");
 await value("select public.rbac_save_user($1,'Delegated settings',true,array[$2::uuid])",[user,role]);
 await staffAs(user,async()=>{
  await assert.rejects(value("select public.rbac_directory()"),/Owner/);
  await assert.rejects(value("select public.sms_settings_status()"),/Owner/);
  await assert.rejects(value("select public.save_settings($1::jsonb)",[JSON.stringify({unit_id:unit})]),/Owner/);
 });
});
test("New Owner authority comes from roles, not legacy admin membership",async()=>{
 const secondOwner=await addStaff(['Owner'],'rbac-second-owner');
 assert.equal(await value("select role from public.memberships where unit_id=$1 and user_id=$2",[unit,secondOwner]),'viewer');
 const proof=`${unit}/rbac-owner-proof.jpg`;await db.query("insert into storage.objects(bucket_id,name) values('payment-proofs',$1)",[proof]);
 await staffAs(secondOwner,async()=>{
 assert.equal((await value<{owner:boolean}>("select public.staff_permissions()")).owner,true);
 await value("select public.sms_settings_status()");
 assert.equal(Number(await value("select count(*) from storage.objects where name=$1",[proof])),1);
 const directory=await value<{users:{id:string}[]}>("select public.rbac_directory()");assert.ok(directory.users.some(u=>u.id===secondOwner));
 });
});

async function supportWorker<T>(action:()=>Promise<T>) {
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try{return await action();}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
}
function inboxMessage(id:string,thread:string,extra:Record<string,unknown>={}) {
 return {gmail_message_id:id,gmail_thread_id:thread,mailbox:"support",sender_email:"support-customer@example.test",sender_name:"TEST-Support Customer",subject:"Question about my tools",rfc_message_id:`<${id}@example.test>`,references_header:"",in_reply_to:"",body:"Please help with my tools.",sent_at:new Date().toISOString(),...extra};
}
test("Support inbox deduplicates mail, opens a numbered case on reply, preserves signature and reopens closed cases",async()=>{
 const customer=await createCustomer("TEST-Support Customer","support-customer");
 const cid=await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-1","thread-1")));
 assert.equal(await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-1","thread-1"))),cid);
 assert.equal(Number(await value("select count(*) from public.support_messages where conversation_id=$1",[cid])),1);
 assert.equal(await value("select customer_id from public.support_conversations where id=$1",[cid]),customer.id);
 assert.equal(await value("select case_code from public.support_conversations where id=$1",[cid]),null);
 await value("select public.support_mark_read($1,now())",[cid]);
 assert.equal(Number(await value("select unread_count from public.support_conversations where id=$1",[cid])),0);
 const replyId=await value<string>("select gen_random_uuid()");
 const reply=await value<{case_code:string;body:string;to:string;mailbox:string}>("select public.support_prepare_reply($1,$2,'Happy to help')",[cid,replyId]);
 assert.match(reply.case_code,/^TT-C-\d{4}-\d{5,}$/);assert.match(reply.body,/Happy to help\n\n/);assert.equal(reply.to,"support-customer@example.test");assert.equal(reply.mailbox,"support");
 await assert.rejects(value("select public.support_prepare_reply($1,$2,'duplicate')",[cid,replyId]),/already submitted/);
 await supportWorker(()=>value("select public.support_finish_reply($1,'Sent','outbox-1','thread-new',null)",[replyId]));
 await value("select public.support_close($1)",[cid]);assert.equal(await value("select status from public.support_conversations where id=$1",[cid]),"Closed");
 const next=await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-2","thread-new")));
 assert.equal(next,cid);assert.equal(await value("select status from public.support_conversations where id=$1",[cid]),"Open");assert.equal(Number(await value("select unread_count from public.support_conversations where id=$1",[cid])),1);
 // Subject and References fallbacks, but never cross customer/department solely from a guessed case folio.
 assert.equal(await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-3","thread-fallback",{subject:`[${reply.case_code}] Re: tools` }))),cid);
 assert.equal(await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-4","thread-header",{in_reply_to:`<${replyId}@tooltag.martinlab.studio>`}))),cid);
 const foreign=await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-spoof","thread-spoof",{sender_email:"other@example.test",subject:`[${reply.case_code}] Question`})));assert.notEqual(foreign,cid);
 const hello=await supportWorker(()=>rpc("support_ingest",inboxMessage("inbox-hello","thread-hello",{mailbox:"hello",subject:`[${reply.case_code}] Question`})));assert.notEqual(hello,cid);
});
test("Support permission is enforced by RLS and RPC, disabled accounts lose inbox access, workers alone can ingest",async()=>{
 const driver=await addStaff(['Driver'],'support-denied-driver');
 await staffAs(driver,async()=>{
 assert.equal(Number(await value("select count(*) from public.support_conversations")),0);assert.equal(Number(await value("select count(*) from public.support_messages")),0);assert.equal(Number(await value("select count(*) from public.support_threads")),0);
 assert.equal(Number(await value("select public.support_attention()")),0);
 await assert.rejects(value("select public.support_close(gen_random_uuid())"),/Support inbox permission/);
 await assert.rejects(rpc("support_ingest",inboxMessage("bad","bad")),/permission denied/);
 });
 const employee=await addStaff(['Employee'],'support-employee');
 await staffAs(employee,async()=>{assert.ok(Number(await value("select count(*) from public.support_conversations"))>0);assert.ok(Number(await value("select public.support_attention()"))>0);await assert.rejects(db.exec("update public.support_conversations set status='Closed'"),/permission denied/);});
 const roles=await value<string[]>("select array_agg(role_id) from public.user_roles where user_id=$1",[employee]);await value("select public.rbac_save_user($1,'Disabled',false,$2::uuid[])",[employee,roles]);
 await staffAs(employee,async()=>{assert.equal(Number(await value("select count(*) from public.support_conversations")),0);});
 await assert.rejects(rpc("support_ingest",inboxMessage("no-worker","no-worker")),/Worker credentials/);
 assert.equal(await value("select has_function_privilege('anon','public.support_ingest(jsonb)','execute')"),false);
 assert.equal(await value("select has_function_privilege('authenticated','public.support_finish_reply(uuid,text,text,text,text)','execute')"),false);
});
test("Support worker leases prevent concurrent pulls and ambiguous replies are never re-sent automatically",async()=>{
 const lease=await supportWorker(()=>value<{lease:string}>("select public.support_begin_sync()"));assert.ok(lease.lease);
 assert.equal(await supportWorker(()=>value("select public.support_begin_sync()")),null);
 await supportWorker(()=>value("select public.support_finish_sync($1,'next-page',null)",[lease.lease]));
 const next=await supportWorker(()=>value<{lease:string;page_token:string}>("select public.support_begin_sync()"));assert.equal(next.page_token,"next-page");
 await supportWorker(()=>value("select public.support_finish_sync($1,null,null)",[next.lease]));
 const cid=await supportWorker(()=>rpc("support_ingest",inboxMessage("unknown-in","unknown-thread")));
 const id=await value<string>("select gen_random_uuid()");await value("select public.support_prepare_reply($1,$2,'Pending test')",[cid,id]);
 await supportWorker(()=>value("select public.support_finish_reply($1,'Unknown',null,null,'GMAIL_DELIVERY_UNKNOWN')",[id]));
 await assert.rejects(value("select public.support_prepare_reply($1,gen_random_uuid(),'do not duplicate')",[cid]),/pending verification/);
 await assert.rejects(value("select public.support_close($1)",[cid]),/pending reply/);
 await supportWorker(()=>value("select public.support_finish_reply($1,'Sent','unknown-reconciled','unknown-thread',null)",[id]));
 assert.equal(await value("select delivery_status from public.support_messages where id=$1",[id]),"Sent");
});

test("Settings profile is Owner-only, ToolTag-only, and partial saves preserve other tabs and policy text",async()=>{
 const before=await value<Record<string,unknown>>("select to_jsonb(s) from public.unit_settings s where unit_id=$1",[unit]);
 const policyBefore=await value<string>("select string_agg(content,'|' order by id) from public.policies where unit_id=$1",[unit]);
 await rpc("save_workspace_profile",{unit_id:unit,business_display_name:"TEST-ToolTag",business_contact_email:" HELLO@EXAMPLE.TEST ",business_contact_phone:"+13852142163"});
 await rpc("save_workspace_profile",{unit_id:unit,route_departure_address:"TEST-Departure · 101 Shop Way, Draper, UT"});
 const current=await value<Record<string,unknown>>("select to_jsonb(s) from public.unit_settings s where unit_id=$1",[unit]);
 assert.equal(current.business_display_name,"TEST-ToolTag");assert.equal(current.business_contact_email,"hello@example.test");assert.equal(current.business_contact_phone,"+13852142163");assert.match(String(current.route_departure_address),/TEST-Departure/);
 for(const key of ['timezone','pickup_route_iso_weekdays','return_route_iso_weekdays','max_pickup_stops_per_saturday','max_delivery_stops_per_sunday','second_delivery_attempt_fee','zelle_email','venmo_handle'])assert.deepEqual(current[key],before[key]);
 assert.equal(await value("select string_agg(content,'|' order by id) from public.policies where unit_id=$1",[unit]),policyBefore);
 const employee=await addStaff(['Employee'],'settings-profile-denied');
 await staffAs(employee,async()=>{await assert.rejects(rpc("save_workspace_profile",{business_display_name:"Unauthorized"}),/Owner access/);});
 const role=await value<string>("select public.rbac_save_role(null,'TEST Settings Only',array['settings.manage'])");
 const user=await value<string>("insert into auth.users(id,email) values(gen_random_uuid(),'settings-only-c@example.test') returning id");
 await value("select public.rbac_save_user($1,'Settings-only staff',true,array[$2]::uuid[])",[user,role]);
 await staffAs(user,async()=>{await assert.rejects(rpc("save_workspace_profile",{business_display_name:"Not Owner"}),/Owner access/);});
 await assert.rejects(rpc("save_workspace_profile",{unit_id:"10000000-0000-0000-0000-000000000001",business_display_name:"Do not touch BOFT"}),/ToolTag workspace only/);
 assert.equal(await value("select has_function_privilege('anon','public.save_workspace_profile(jsonb)','execute')"),false);
});
test("Settings profile validates email and limits, supports clearing optional values, and existing settings cannot overwrite it",async()=>{
 await assert.rejects(rpc("save_workspace_profile",{business_contact_email:"bad email"}),/valid business email/);
 await assert.rejects(rpc("save_workspace_profile",{business_display_name:"X".repeat(161)}),/check constraint/);
 await assert.rejects(rpc("save_workspace_profile",{route_departure_address:{nested:"invalid"}}),/Invalid workspace field/);
 const departure=await value("select route_departure_address from public.unit_settings where unit_id=$1",[unit]);
 await rpc("save_settings",{unit_id:unit,zelle_email:"payments@example.test"});
 assert.equal(await value("select route_departure_address from public.unit_settings where unit_id=$1",[unit]),departure);
 await rpc("save_workspace_profile",{business_contact_phone:" ",business_contact_email:""});
 assert.equal(await value("select business_contact_phone from public.unit_settings where unit_id=$1",[unit]),null);
 assert.equal(await value("select business_contact_email from public.unit_settings where unit_id=$1",[unit]),null);
});

const fixtureSmsConsent={granted:true,phone:"+13852142163",privacy_url:"https://tooltag.example/privacy",terms_url:"https://tooltag.example/terms",disclosure:"Fixture explicit ToolTag SMS consent"};
test("Get Tagged records explicit consent on its Draft Quote flow, never auto-opts-in or replays notifications",async()=>{
 const customer=await createCustomer("TEST-Intake Consent","intake-sms"),quote=await createQuote(customer.id);
 const flow=await value<string>("select flow_id from public.quotes where id=$1",[quote]);
 const deliveries=Number(await value("select count(*) from private.sms_deliveries"));
 const receipt=await value<string>("insert into private.get_tagged_receipts(id,fingerprint,details,matching,candidates,quote_id,customer_id) values(gen_random_uuid(),repeat('a',64),$1::jsonb,'created','{}',$2,$3) returning id",[JSON.stringify({contact:{name:"TEST-Intake Consent",email:"intake-sms@example.test",phone:"3852142163"},sms:fixtureSmsConsent}),quote,customer.id]);
 assert.equal(await value("select granted from private.sms_consents where flow_id=$1",[flow]),true);assert.equal(await value("select phone from private.sms_consents where flow_id=$1",[flow]),"+13852142163");
 assert.match(await value<string>("select disclosure from private.sms_consent_events where flow_id=$1",[flow]),/Privacy Policy: https:\/\/tooltag.example\/privacy/);
 await db.query("update private.get_tagged_receipts set quote_id=quote_id where id=$1",[receipt]);assert.equal(Number(await value("select count(*) from private.sms_consent_events where flow_id=$1",[flow])),1);
 assert.equal(Number(await value("select count(*) from private.sms_deliveries")),deliveries);
 const other=await createQuote(customer.id);const otherFlow=await value<string>("select flow_id from public.quotes where id=$1",[other]);
 await value("select private.record_web_sms_consent($1,$2::jsonb,'get-tagged')",[otherFlow,JSON.stringify({...fixtureSmsConsent,granted:false})]);assert.equal(Number(await value("select count(*) from private.sms_consents where flow_id=$1",[otherFlow])),0);
 await assert.rejects(value("select private.record_web_sms_consent($1,$2::jsonb,'get-tagged')",[otherFlow,JSON.stringify({...fixtureSmsConsent,privacy_url:""})]),/published policy links/);
});
test("Cancellation phone lookup opt-in is service-only and cannot change the consent recipient",async()=>{
 const customer=await createCustomer("TEST-Lookup Consent","lookup-sms"),quote=await createQuote(customer.id);
 await value("select public.send_quote($1)",[quote]);
 const consent={...fixtureSmsConsent,phone:"+1"+customer.phone};
 const args=['d'.repeat(64),"TEST-Lookup Consent","lookup-sms@example.test",customer.phone,JSON.stringify(consent)];
 await assert.rejects(value("select public.request_cancellation_access_with_sms($1,$2,$3,$4,$5::jsonb)",args),/Server credentials/);
 await supportWorker(()=>value("select public.request_cancellation_access_with_sms($1,$2,$3,$4,$5::jsonb)",args));
 const flow=await value<string>("select flow_id from public.quotes where id=$1",[quote]);assert.equal(await value("select phone from private.sms_consents where flow_id=$1",[flow]),consent.phone);
 await supportWorker(async()=>{await assert.rejects(value("select public.request_cancellation_access_with_sms($1,$2,$3,$4,$5::jsonb)",[...args.slice(0,4),JSON.stringify(fixtureSmsConsent)]),/entered customer phone/);});
 assert.equal(await value("select has_function_privilege('anon','public.request_cancellation_access_with_sms(text,text,text,text,jsonb)','execute')"),false);
});

test("Status SMS opt-in queues one welcome first and never replays older notifications",async()=>{
 const {job,token}=await readyReturn("sms-status-welcome");
 const flow=await value<string>("select flow_id from public.jobs where id=$1",[job]);
 await db.query("update private.sms_settings set enabled=true,activated_at=now()-interval '1 day' where unit_id=$1",[unit]);
 const old=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload,created_at) values($1,'JOB_STATUS_UPDATE',$2,'sms-old:'||($2::uuid)::text,'{}',now()-interval '1 hour') returning id",[unit,job]);
 await value("select public.set_sms_consent($1,'status','+18015550199',true)",[token]);
 const grantedAt=await value("select granted_at::text from private.sms_consents where flow_id=$1",[flow]);
 await value("select public.set_sms_consent($1,'status','+18015550199',true)",[token]);
 assert.equal(String(await value("select granted_at::text from private.sms_consents where flow_id=$1",[flow])),String(grantedAt));
 assert.equal(Number(await value("select count(*) from public.notifications where entity_id=$1 and event='SMS_WELCOME'",[job])),1);
 assert.equal(await value("select status from private.sms_deliveries where notification_id=$1",[old]),"Skipped");
 const welcome=await value<string>("select id from public.notifications where entity_id=$1 and event='SMS_WELCOME'",[job]);
 const future=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload) values($1,'JOB_STATUS_UPDATE',$2,'sms-future:'||($2::uuid)::text,'{}') returning id",[unit,job]);
 // Isolate this test's queue from earlier fixture notifications; never contacts SNS.
 await db.query("update private.sms_deliveries set status='Skipped' where status='Pending' and flow_id is distinct from $1",[flow]);
 await supportWorker(async()=>{
 const first=await value<{id:string;claim:string}>("select public.claim_sms()");assert.equal(first.id,welcome);
 assert.equal(await value("select public.claim_sms()"),null);
 await value("select public.finish_sms($1,$2,'Sent','mock-welcome',null)",[first.id,first.claim]);
 const second=await value<{id:string}>("select public.claim_sms()");assert.equal(second.id,future);
 });
 await assert.rejects(value("select public.set_sms_consent('bad','status','+18015550199',true)"),/unavailable/);
});

test("Public intake accepts an omitted phone without matching other blank-phone customers",async()=>{
 const existing=await createCustomer("Blank Phone Existing","blank-phone-existing");
 await db.query("update public.customers set phone='' where id=$1",[existing.id]);
 await supportWorker(async()=>{
 const payload={contact:{name:"Optional Phone Customer",email:"optional-intake@example.test",phone:""},service:{method:"Drop-off"},quote_items:[{article:"Battery",quantity:1}],sms:{granted:false}};
 const key="92000000-0000-0000-0000-000000000099";
 const result=await value<{reference:string}>("select public.submit_get_tagged_v2($1,$2,$3::jsonb)",[key,"1".repeat(64),JSON.stringify(payload)]);assert.ok(result.reference);
 assert.equal(await value("select matching from private.get_tagged_receipts where id=$1",[key]),"new");
 assert.equal(Number(await value("select cardinality(candidates) from private.get_tagged_receipts where id=$1",[key])),0);
 });
});

test("Utah tax pins Quote rate and charges the taxed service and logistics amounts",async()=>{
 await value("select public.save_sales_tax_rate(7.45)");
 try {
 const customer=await createCustomer("Utah Tax Customer","utah-tax");const quote=await createQuote(customer.id,"40.00");
 const token=await value<string>("select public.send_quote($1)",[quote]);
 let preview=await value<{subtotal:number;tax_rate:number;tax_amount:number;total:number}>("select public.public_quote($1)",[token]);
 assert.equal(preview.subtotal,40);assert.equal(preview.tax_amount,2.98);assert.equal(preview.total,42.98);
 await value("select public.save_sales_tax_rate(8)");
 preview=await value("select public.public_quote($1)",[token]);assert.equal(preview.tax_rate,7.45);
 const accepted=await acceptWithLogistics(token,{option_code:"pickup_delivery",pickup_address:"101 Tax Way, Draper, UT",delivery_address:"101 Tax Way, Draper, UT",saturday_date:futureSaturday()});
 const snapshot=await value<{subtotal:number;tax_rate:number;tax_amount:number;total:number}>("select commercial_snapshot from public.agreements where quote_id=$1",[quote]);
 assert.equal(snapshot.subtotal,59.99);assert.equal(snapshot.tax_amount,4.47);assert.equal(snapshot.total,64.46);
 assert.equal(Number(await value("select f.revenue from public.financial_effects f join public.sales s on s.transaction_id=f.id where s.quote_id=$1",[quote])),59.99);
 assert.equal(Number(await value("select grand_total from public.job_commercial_totals where id=$1",[accepted.job_id])),64.46);
 assert.equal(Number(await value("select fee_amount from public.pick_return_orders where job_id=$1",[accepted.job_id])),21.48);
 const full=await value<{amount:number}>("select public.prepare_logistics_payment($1,'full','Card',gen_random_uuid())",[token]);assert.equal(full.amount,64.46);
 const fee=await value<{amount:number}>("select public.prepare_logistics_payment($1,'fee_only','Card',gen_random_uuid())",[token]);assert.equal(fee.amount,21.48);
 const payment=await value<{subtotal:number;tax_amount:number;total:number}>("select public.public_payment_tax($1,'review')",[token]);assert.equal(payment.total,64.46);assert.equal(payment.tax_amount,4.47);
 await value("select public.save_sales_tax_rate(9)");
 assert.deepEqual(await value("select commercial_snapshot from public.agreements where quote_id=$1",[quote]),snapshot);
 await assert.rejects(value("select public.public_payment_tax('wrong','review')"),/invalid|expired/i);
 await assert.rejects(value("select public.save_sales_tax_rate(101)"),/Tax rate/);
 }finally{await value("select public.save_sales_tax_rate(0)");}
});

test("Extension proposals and second Return fees preserve their taxable totals",async()=>{
 await value("select public.save_sales_tax_rate(7.45)");
 try {
 const {job,token}=await readyReturn("tax-extension-return");
 const extension=await value<string>("select public.request_job_extension($1,'Extra engraving',gen_random_uuid())",[job]);
 await rpc("save_job_extension",{id:extension,notes:"Extra engraving",items:[{article:"Battery",quantity:1,unit_price:"20.00",engraving_type:"Text",engraving_text:"TEST",marks:[{type:"Text",text:"TEST",location:"Left",paint_fill:false}],paint_fill:false,colors:0}]});
 assert.equal(Number(await value("select total from public.job_extensions where id=$1",[extension])),21.49);
 const extToken=await value<string>("select public.send_job_extension($1)",[extension]);
 const proposal=await value<{subtotal:number;tax_amount:number;total:number}>("select public.public_extension($1)",[extToken]);assert.equal(proposal.subtotal,20);assert.equal(proposal.tax_amount,1.49);assert.equal(proposal.total,21.49);
 await value("select public.save_sales_tax_rate(8)");assert.equal(Number(await value("select total from public.job_extensions where id=$1",[extension])),21.49);
 await db.query("update public.job_extensions set status='Cancelled' where id=$1",[extension]);
 const stop=await value<string>("select s.id from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[job]);
 await db.query("update public.pick_return_stops set status='Arrived' where id=$1",[stop]);await value("select public.advance_pick_return_stop($1,'not-home')",[stop]);
 await value("select public.choose_second_return($1,$2)",[job,token]);
 assert.equal(Number(await value("select amount from public.delivery_attempt_fees where job_id=$1",[job])),10.75);
 const retrySnapshot=await value<{subtotal:number;tax_amount:number}>("select s.tax_snapshot from public.sales s join public.delivery_attempt_fees f on f.sale_id=s.transaction_id where f.job_id=$1",[job]);assert.equal(retrySnapshot.subtotal,10);assert.equal(retrySnapshot.tax_amount,.75);
 }finally{await value("select public.save_sales_tax_rate(0)");}
});

test('Refunds reserve paid amounts, enforce 14 calendar days, business-day windows and reject proof from another request',async()=>{
 const c=await createCustomer('Refund policy test','refund-policy');const q=await createQuote(c.id,'40.00');const token=await value<string>('select public.send_quote($1)',[q]);const accepted=await acceptWithLogistics(token,{option_code:'dropoff_pickup'});const job=accepted.job_id;
 const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',40,'Final Balance') returning id",[unit,job]);await value('select public.confirm_payment_request($1)',[payment]);
 const date=await value<string>("select (now()-interval '14 days')::text");const now=await value<string>('select now()::text');
 const key=await value<string>('select gen_random_uuid()');const payload={job_id:job,amount:'10.00',reason:'Damage',issue_event:'Pickup',issue_event_at:date,reported_at:now,request_key:key};
 const id=await rpc('create_refund_request',payload);assert.equal(await rpc('create_refund_request',payload),id);
 assert.equal(Number(await value('select count(*) from public.refund_requests where request_key=$1',[key])),1);
 await assert.rejects(rpc('create_refund_request',{...payload,amount:'11.00'}),/different refund information/);
 await assert.rejects(rpc('create_refund_request',{...payload,request_key:await value('select gen_random_uuid()'),issue_event_at:await value("select (now()-interval '15 days')::text")}),/14 days/);
 await assert.rejects(rpc('create_refund_request',{...payload,request_key:await value('select gen_random_uuid()'),amount:'31.00'}),/actually paid/);
 await assert.rejects(rpc('create_refund_request',{...payload,request_key:await value('select gen_random_uuid()'),method:'Cash'}),/check constraint/);
 assert.equal(await value("select private.refund_business_date('2026-10-09',5)::text"),'2026-10-16');assert.equal(await value("select private.refund_business_date('2026-10-09',7)::text"),'2026-10-20');
 const account=await value<string>('select t.account_id from public.transactions t join public.collections c on c.transaction_id=t.id join public.sales s on s.transaction_id=c.sale_id where s.job_id=$1 limit 1',[job]);
 const second=await rpc('create_refund_request',{...payload,request_key:await value('select gen_random_uuid()'),amount:'5.00'});const wrongProof=await manualRefundProof(job,second);await confirmRefundWindow(id);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Zelle',account_id:account,reference:'wrongproof',proof_id:wrongProof}),/proof belonging/);
 await rpc('refund_request_action',{id:second,action:'cancel',notes:'Duplicate report'});assert.equal(await value('select status from public.refund_requests where id=$1',[second]),'Cancelled');
 const proof=await manualRefundProof(job,id);await rpc('refund_request_action',{id,action:'complete',method:'Check',account_id:account,reference:'CHECK-101',proof_id:proof});
 assert.equal(await value('select processed_by from public.refund_requests where id=$1',[id]),admin);
 const choice=(await value<{id:string;available:number}[]>('select public.refund_job_choices()')).find(x=>x.id===job)!;assert.equal(Number(choice.available),30);
 await db.query("update public.jobs set completion_email_sent_at=now()-interval '15 days' where id=$1",[job]);
 await assert.rejects(rpc('create_refund_request',{...payload,request_key:await value('select gen_random_uuid()'),issue_event:'Completion notice',issue_event_at:now}),/14 days/);
});

test('Refund-only staff can use Job selector, upload scoped proof and manage refunds; read-only staff cannot mutate',async()=>{
 const c=await createCustomer('Refund access test','refund-access');const q=await createQuote(c.id);const token=await value<string>('select public.send_quote($1)',[q]);const accepted=await acceptWithLogistics(token,{option_code:'dropoff_pickup'});
 const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',40,'Final Balance') returning id",[unit,accepted.job_id]);await value('select public.confirm_payment_request($1)',[payment]);
 const staff=await addStaff([],'refund-only');const role=await value<string>("select public.rbac_save_role(null,'Refund specialist',array['payments.refund'])");await value("select public.rbac_save_user($1,'Refund specialist',true,array[$2::uuid])",[staff,role]);
 let request='',proof='';
 await staffAs(staff,async()=>{
 assert.ok((await value<{id:string}[]>('select public.refund_job_choices()')).some(j=>j.id===accepted.job_id));
 const now=new Date().toISOString();request=await rpc('create_refund_request',{request_key:await value('select gen_random_uuid()'),job_id:accepted.job_id,amount:'5.00',reason:'ToolTag error',issue_event:'Completion notice',issue_event_at:now,reported_at:now});
 proof=await rpc('register_document_metadata',{unit_id:unit,job_id:accepted.job_id,refund_request_id:request,type:'Refund Review Evidence',file_name:'refund-proof.png',mime_type:'image/png',file_size:100,sha256:'d'.repeat(64),visibility:'internal'});
 assert.equal(await value('select refund_request_id from public.documents where id=$1',[proof]),request);
 await assert.rejects(rpc('register_document_metadata',{unit_id:unit,job_id:accepted.job_id,refund_request_id:request,type:'Receiving Evidence',file_name:'wrong.png',file_size:100,sha256:'e'.repeat(64)}),/Invalid refund proof/);
 await rpc('refund_request_action',{id:request,action:'confirm'});
 });
 const viewer=await addStaff([],'refund-readonly');const viewRole=await value<string>("select public.rbac_save_role(null,'Refund viewer',array['payments.view'])");await value("select public.rbac_save_user($1,'Refund viewer',true,array[$2::uuid])",[viewer,viewRole]);
 await staffAs(viewer,async()=>{assert.equal(Number(await value('select count(*) from public.refund_requests where id=$1',[request])),1);assert.equal(Number(await value('select count(*) from public.documents where id=$1',[proof])),1);await assert.rejects(rpc('refund_request_action',{id:request,action:'cancel'}),/permission/);});
 const driver=await addStaff(['Driver'],'refund-driver');await staffAs(driver,async()=>{assert.equal(Number(await value('select count(*) from public.refund_requests')),0);await assert.rejects(value('select public.refund_job_choices()'),/access required/);});
});

test('Original Cash payments require an electronic or Check refund and retain the actual disbursement account',async()=>{
 const c=await createCustomer('Cash refund test','refund-cash');const q=await createQuote(c.id);const token=await value<string>('select public.send_quote($1)',[q]);const accepted=await acceptWithLogistics(token,{option_code:'dropoff_pickup'});
 const payment=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',40,'Final Balance') returning id",[unit,accepted.job_id]);await value('select public.confirm_payment_request($1)',[payment]);
 await db.query("update public.transactions set payment_method='Cash' where id in(select c.transaction_id from public.collections c join public.sales s on s.transaction_id=c.sale_id where s.job_id=$1)",[accepted.job_id]);
 const now=new Date().toISOString();const id=await rpc('create_refund_request',{request_key:await value('select gen_random_uuid()'),job_id:accepted.job_id,amount:'5.00',reason:'Other',issue_event:'Pickup',issue_event_at:now,reported_at:now});
 assert.equal(await value('select original_method from public.refund_requests where id=$1',[id]),'Cash');assert.equal(await value('select method from public.refund_requests where id=$1',[id]),null);
 await confirmRefundWindow(id);const proof=await manualRefundProof(accepted.job_id,id);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Cash',proof_id:proof,reference:'NO-CASH'}),/Cash/);
 await assert.rejects(rpc('refund_request_action',{id,action:'complete',method:'Zelle',proof_id:proof,reference:'REF-ZELLE'}),/account/);
 const account=await value<string>('select id from public.accounts where unit_id=$1 and active limit 1',[unit]);
 await rpc('refund_request_action',{id,action:'complete',method:'Zelle',account_id:account,proof_id:proof,reference:'REF-ZELLE'});
 assert.equal(await value("select account_id from public.transactions where type='REFUND' and reference='REF-ZELLE'"),account);
 assert.equal(await value('select method from public.refund_requests where id=$1',[id]),'Zelle');
});

let smsCostSequence=0;
async function smsCostFixtureSend(quote:string,status='Sent',provider?:string){
 const id=await value<string>("insert into public.notifications(unit_id,event,entity_id,dedupe_key) values($1,'Quote Sent',$2,$3) returning id",[unit,quote,'sms-cost-test:'+ ++smsCostSequence]);
 const claim=await value<string>("update private.sms_deliveries set status='Sending',claim=gen_random_uuid(),claimed_at=now() where notification_id=$1 returning claim",[id]);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");
 try{await value('select public.finish_sms($1,$2,$3,$4,null)',[id,claim,status,provider??(status==='Sent'?'aws-cost-test-'+smsCostSequence:null)]);}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 return {id,claim};
}
async function reconcileSmsCosts(){await db.query("select set_config('request.jwt.claim.role','service_role',false)");try{await value('select public.reconcile_sms_costs()');}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}}
test('SMS costs count AWS-accepted sends once, preserve precision and post an expired Quote expense only once',async()=>{
 const c=await createCustomer('SMS quote costs','sms-quote-costs');const q=await createQuote(c.id);const flow=await value<string>('select flow_id from public.quotes where id=$1',[q]);
 const first=await smsCostFixtureSend(q);
 await smsCostFixtureSend(q,'Failed');await smsCostFixtureSend(q,'Unknown');await smsCostFixtureSend(q,'Skipped');
 for(let i=1;i<10;i++)await smsCostFixtureSend(q);
 assert.equal(Number(await value('select sms_count from public.sms_cost_totals where flow_id=$1',[flow])),10);
 assert.equal(Number(await value('select exact_cost from public.sms_cost_totals where flow_id=$1',[flow])),0.0645);
 assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where flow_id=$1',[flow])),0);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");try{assert.equal(await value("select public.finish_sms($1,$2,'Sent','duplicate',null)",[first.id,first.claim]),false);}finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 await db.query("update public.quotes set status='Expired' where id=$1",[q]);await reconcileSmsCosts();await reconcileSmsCosts();
 const total=await value<string>('select id from public.sms_cost_totals where flow_id=$1',[flow]);
 assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where id=$1',[total])),0.06);
 assert.equal(Number(await value('select count(*) from public.expenses where sms_cost_total_id=$1',[total])),1);
 const expense=await value<{reference:string;name:string;amount:number}>("select jsonb_build_object('reference',t.reference,'name',cat.name,'amount',t.amount) from public.expenses e join public.transactions t on t.id=e.transaction_id join public.categories cat on cat.id=t.category_id where e.sms_cost_total_id=$1",[total]);assert.equal(expense.name,'SMS');assert.equal(Number(expense.amount),0.06);assert.match(expense.reference,/^SMS-Quote-/);
});
test('SMS costing transfers the Quote total to its Job, pins send rates and adds only the rounded late-send delta',async()=>{
 const c=await createCustomer('SMS job costs','sms-job-costs');const q=await createQuote(c.id);await smsCostFixtureSend(q);const token=await value<string>('select public.send_quote($1)',[q]);const accepted=await acceptWithLogistics(token,{option_code:'dropoff_pickup'});const job=accepted.job_id;
 assert.equal(Number(await value('select sms_count from public.sms_cost_totals where job_id=$1',[job])),1);
 const account=await value<string>('select sms_expense_account_id from public.unit_settings where unit_id=$1',[unit]);await value('select public.save_sms_cost_settings(0.01,$1)',[account]);
 try{
 await smsCostFixtureSend(q);
 assert.equal(Number(await value('select exact_cost from public.sms_cost_totals where job_id=$1',[job])),0.01645);
 await db.query("update public.jobs set status='Completed' where id=$1",[job]);
 assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where job_id=$1',[job])),0.02);
 await smsCostFixtureSend(q);
 assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where job_id=$1',[job])),0.03);
 await reconcileSmsCosts();assert.equal(Number(await value('select count(*) from public.expenses e join public.sms_cost_totals a on a.id=e.sms_cost_total_id where a.job_id=$1',[job])),2);
 assert.equal(Number(await value('select sum(t.amount) from public.expenses e join public.transactions t on t.id=e.transaction_id join public.sms_cost_totals a on a.id=e.sms_cost_total_id where a.job_id=$1',[job])),0.03);
 const snap=await value<{job_id:string;quote_id:string;sms_count:number;rates:unknown[]}>('select e.sms_cost_snapshot from public.expenses e join public.sms_cost_totals a on a.id=e.sms_cost_total_id where a.job_id=$1 order by e.transaction_id limit 1',[job]);assert.equal(snap.job_id,job);assert.equal(snap.quote_id,q);assert.equal(snap.rates.length,2);
 }finally{await value('select public.save_sms_cost_settings(0.00645,$1)',[account]);}
});
test('Deleted Quotes retain SMS cost origin and accounting failure never loses a sent SMS',async()=>{
 const c=await createCustomer('SMS deletion costs','sms-delete-costs');const q=await createQuote(c.id);await smsCostFixtureSend(q);const code=await value<string>('select code from public.quotes where id=$1',[q]);const total=await value<string>('select id from public.sms_cost_totals where quote_id=$1',[q]);
 await db.query('delete from public.quote_items where quote_id=$1',[q]);await db.query('delete from public.quotes where id=$1',[q]);assert.equal(await value('select quote_id from public.sms_cost_totals where id=$1',[total]),null);assert.equal(await value('select quote_code from public.sms_cost_totals where id=$1',[total]),code);assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where id=$1',[total])),0.01);
 const q2=await createQuote(c.id);const account=await value<string>('select sms_expense_account_id from public.unit_settings where unit_id=$1',[unit]);await db.query('update public.unit_settings set sms_expense_account_id=null where unit_id=$1',[unit]);
 try{
 await db.query("update public.quotes set status='Expired' where id=$1",[q2]);await smsCostFixtureSend(q2);
 assert.equal(Number(await value('select sms_count from public.sms_cost_totals where quote_id=$1',[q2])),1);assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where quote_id=$1',[q2])),0);assert.match(await value<string>('select posting_error from public.sms_cost_totals where quote_id=$1',[q2]),/account/);
 }finally{await value('select public.save_sms_cost_settings(0.00645,$1)',[account]);}
 await reconcileSmsCosts();await reconcileSmsCosts();assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where quote_id=$1',[q2])),0.01);
});
test('SMS cost settings and trace data enforce Owner/Finance permissions and provider IDs cannot be counted twice',async()=>{
 const c=await createCustomer('SMS permissions','sms-cost-permissions');const q=await createQuote(c.id);await smsCostFixtureSend(q,'Sent','aws-duplicate-cost');await smsCostFixtureSend(q,'Sent','aws-duplicate-cost');assert.equal(Number(await value('select sms_count from public.sms_cost_totals where quote_id=$1',[q])),1);
 const account=await value<string>('select sms_expense_account_id from public.unit_settings where unit_id=$1',[unit]);await assert.rejects(value('select public.save_sms_cost_settings(-1,$1)',[account]),/nonnegative/);
 const employee=await addStaff(['Employee'],'sms-cost-employee');await staffAs(employee,async()=>{assert.equal(Number(await value('select count(*) from public.sms_cost_totals')),0);await assert.rejects(value('select public.save_sms_cost_settings(1,$1)',[account]),/Owner/);await assert.rejects(value('select public.reconcile_sms_costs()'),/credentials|permission denied/);});
});

test('AWS acceptance is chargeable even if delivery fails; delivery metadata never reverses or doubles the cost',async()=>{
 const c=await createCustomer('SNS acceptance accounting','sms-accepted-not-delivered');const q=await createQuote(c.id);await smsCostFixtureSend(q,'Failed','aws-accepted-failed');await smsCostFixtureSend(q,'Sent','aws-accepted-delivered');await smsCostFixtureSend(q,'Failed');await smsCostFixtureSend(q,'Unknown');
 assert.equal(Number(await value('select sms_count from public.sms_cost_totals where quote_id=$1',[q])),2);assert.equal(Number(await value('select exact_cost from public.sms_cost_totals where quote_id=$1',[q])),0.0129);
 assert.equal(Number(await value('select delivery_failed_count from public.sms_cost_totals where quote_id=$1',[q])),0);assert.equal(Number(await value('select delivery_unknown_count from public.sms_cost_totals where quote_id=$1',[q])),2);assert.equal(Number(await value('select acceptance_unknown_count from public.sms_cost_totals where quote_id=$1',[q])),1);
 await db.query("update public.quotes set status='Expired' where id=$1",[q]);
 await db.query("select set_config('request.jwt.claim.role','service_role',false)");try{
 await value("select public.record_sms_delivery_outcome('aws-accepted-delivered','Delivered',null,now())");await value("select public.record_sms_delivery_outcome('aws-accepted-failed','Failed','Carrier unavailable',now())");await value("select public.record_sms_delivery_outcome('aws-accepted-failed','Failed','Carrier unavailable',now())");
 }finally{await db.query("select set_config('request.jwt.claim.role','authenticated',false)");}
 assert.equal(Number(await value('select delivered_count from public.sms_cost_totals where quote_id=$1',[q])),1);assert.equal(Number(await value('select delivery_failed_count from public.sms_cost_totals where quote_id=$1',[q])),1);assert.equal(Number(await value('select sms_count from public.sms_cost_totals where quote_id=$1',[q])),2);assert.equal(Number(await value('select posted_amount from public.sms_cost_totals where quote_id=$1',[q])),0.01);
});

async function blockReject(promise:()=>Promise<unknown>,pattern:RegExp) {
 await db.exec("savepoint expected_error");try {await assert.rejects(promise(),pattern);}finally{await db.exec("rollback to savepoint expected_error; release savepoint expected_error");}
}

// Keep legacy scheduling regressions above, and exercise the production shop-controlled mode here.
test('Shop delivery blocks queue finished jobs, allocate atomically, preserve existing routes, reorder and remove to the queue',async()=>{
 await db.exec('begin');
 try {
  await db.query('update public.unit_settings set shop_delivery_blocks_enabled=true where unit_id=$1',[unit]);
  const a=await readyReturn('blocks-first');const b=await readyReturn('blocks-second');
  await db.query("update public.pick_return_orders set production_ready_at=now()-interval '2 days' where job_id=$1",[a.job]);
  await db.query("update public.pick_return_orders set production_ready_at=now()-interval '1 day' where job_id=$1",[b.job]);
  assert.equal(Number(await value("select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=$1 and r.leg='Return' and s.status='Scheduled'",[a.job])),0);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[a.job]),true);
  const days=await value<{date:string;blocks:{number:number;capacity:number}[]}[]>('select public.delivery_block_availability($1,(now()::date+30))',[a.job]);
  assert.ok(days.length);assert.equal(days[0].blocks[0].number,1);assert.equal(days[0].blocks[0].capacity,20);
  const route=await value<string>('select public.assign_delivery_block($1,$2)',[a.job,days[0].date]);
  await value('select private.auto_return($1)',[a.job]);
  assert.equal(await value('select return_window_start is not null from public.pick_return_orders where job_id=$1',[a.job]),true,'Worker keeps the existing shop assignment');
  assert.equal(await value('select public.assign_delivery_block($1,$2)',[b.job,days[0].date]),route);
  const stops=await db.query<{id:string;job_id:string}>('select id,job_id from public.pick_return_stops where route_id=$1 and status<>\'Cancelled\' order by sequence',[route]);
  assert.deepEqual(stops.rows.map(s=>s.job_id),[a.job,b.job]);
  const reversed=stops.rows.map(s=>s.id).reverse();
  await value("select public.save_delivery_block($1,null,$2::uuid[],'{}',20,null)",[route,reversed]);
  assert.deepEqual((await db.query<{id:string}>('select id from public.pick_return_stops where route_id=$1 and status<>\'Cancelled\' order by sequence',[route])).rows.map(s=>s.id),reversed);
  await value("select public.save_delivery_block($1,null,$2::uuid[],$3::uuid[],20,null)",[route,[reversed[0]],[reversed[1]]]);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[a.job]),true);
  assert.equal(Number(await value('select count(*) from public.pick_return_routes where id=$1',[route])),1);
  await blockReject(()=>value("select public.save_delivery_block($1,null,$2::uuid[],'{}',20,null)",[route,[reversed[0],reversed[0]]]),/changed/);
  const stop=reversed[0];await db.query("update public.pick_return_stops set status='Failed' where id=$1",[stop]);
  await blockReject(()=>value('select public.confirm_pick_return_route($1)',[route]),/verify each item/);
  const items=await db.query<{id:string}>('select id from public.job_items where job_id=$1',[b.job]);
  await value("select public.verify_route_items($1,'Returned',$2::uuid[])",[stop,items.rows.map(i=>i.id)]);
  await value('select public.confirm_pick_return_route($1)',[route]);
  assert.equal(await value('select confirmed_at is not null from public.pick_return_routes where id=$1',[route]),true);
 } finally {await db.exec('rollback');}
});

test('Shop delivery misses reserve no route, wait for paid retry, then requeue once; 15 unpaid days require shop pickup',async()=>{
 await db.exec('begin');
 try {
  const f=await driverReturnFixture('blocks-retry');
  await db.query('update public.unit_settings set shop_delivery_blocks_enabled=true where unit_id=$1',[unit]);
  await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);
  await db.query("update public.pick_return_stops set return_wait_until=now()-interval '1 second' where id=$1",[f.stop]);
  await value("select public.return_driver_action($1,'not-home')",[f.stop]);
  assert.equal(await value('select return_reservation_stop_id from public.pick_return_orders where job_id=$1',[f.job]),null);
  assert.equal(await value('select return_window_start from public.pick_return_orders where job_id=$1',[f.job]),null);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[f.job]),false);
  assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Requested'",[f.job])),0);
  await value('select public.choose_second_return($1,$2)',[f.job,f.token]);
  const due=await value<number>('select balance_due from public.job_commercial_totals where id=$1',[f.job]);
  const pay=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) values(gen_random_uuid(),$1,$2,'Zelle',$3,'Final Balance') returning id",[unit,f.job,due]);
  await value('select public.confirm_payment_request($1)',[pay]);await value('select private.reconcile_delivery($1)',[f.job]);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[f.job]),true);
  assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status in ('Requested','Scheduled')",[f.job])),0);
  const notice=await value<string>("select payload::text from public.notifications where dedupe_key=$1",['return-missed:'+f.stop]);assert.match(notice,/schedule.*shop/);
  await db.query("update public.pick_return_orders set return_reservation_expires_at=now()-interval '1 second' where job_id=$1",[f.job]);
  // A paid retry remains eligible even if the former unpaid deadline has passed.
  await value('select private.reconcile_delivery($1)',[f.job]);assert.equal(await value('select private.delivery_queue_eligible($1)',[f.job]),true);
 } finally {await db.exec('rollback');}
});

test('Delivery capacity is enforced at 20 across RPCs, hides full dates, and only an Owner can authorize extra stops',async()=>{
 await db.exec('begin');
 try {
  await db.query('update public.unit_settings set shop_delivery_blocks_enabled=true where unit_id=$1',[unit]);
  const first=await readyReturn('capacity-0');
  const dates=await value<{date:string}[]>('select public.delivery_block_availability($1,now()::date+42)',[first.job]);const day=dates[0].date;
  const route=await value<string>('select public.assign_delivery_block($1,$2)',[first.job,day]);
  for(let i=1;i<20;i++){const f=await readyReturn(`capacity-${i}`);await value('select public.assign_delivery_block($1,$2)',[f.job,day]);}
  const extra=await readyReturn('capacity-extra');
  assert.equal(Number(await value("select count(*) from public.pick_return_stops where route_id=$1 and status<>'Cancelled'",[route])),20);
  const full=await value<{date:string}[]>('select public.delivery_block_availability($1,$2)',[extra.job,day]);assert.ok(full.every(d=>d.date!==day));
  await blockReject(()=>value('select public.assign_delivery_block($1,$2)',[extra.job,day]),/no longer available/);
  await blockReject(()=>value("select private.assign_route($1,'Return',($2::date+time '14:00') at time zone 'America/Denver',($2::date+time '18:00') at time zone 'America/Denver')",[extra.job,day]),/block is full/);
  const ids=await value<string[]>("select array_agg(id order by sequence) from public.pick_return_stops where route_id=$1 and status<>'Cancelled'",[route]);
  const employee='90000000-0000-0000-0000-000000000097';
  await db.query('insert into auth.users(id) values($1)',[employee]);await db.query("insert into public.memberships(unit_id,user_id,role) values($1,$2,'viewer')",[unit,employee]);
  const role=await value<string>("select id from public.roles where unit_id=$1 and system_key='Employee'",[unit]);await value("select public.rbac_save_user($1,'Capacity employee',true,array[$2::uuid])",[employee,role]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[employee]);
  await blockReject(()=>value("select public.save_delivery_block($1,null,$2::uuid[],'{}',21,'Test exception')",[route,ids]),/Owner/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.session_id',$1,false)",[admin]);
  await value("select public.save_delivery_block($1,null,$2::uuid[],'{}',21,'Test exception')",[route,ids]);
  assert.equal(await value('select capacity_authorized_by::text from public.pick_return_routes where id=$1',[route]),admin);
  await value('select public.assign_delivery_block($1,$2)',[extra.job,day]);
  assert.equal(Number(await value("select count(*) from public.pick_return_stops where route_id=$1 and status<>'Cancelled'",[route])),21);
 }finally{await db.exec('rollback');}
});

test('An unpaid missed delivery disappears from monitoring after 15 days and remains a free shop-pickup Job',async()=>{
 await db.exec('begin');
 try {
  const f=await driverReturnFixture('blocks-unpaid-expiry');
  await db.query('update public.unit_settings set shop_delivery_blocks_enabled=true where unit_id=$1',[unit]);
  await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);
  await db.query("update public.pick_return_stops set return_wait_until=now()-interval '1 second' where id=$1",[f.stop]);await value("select public.return_driver_action($1,'not-home')",[f.stop]);
  await db.query("update public.pick_return_orders set return_reservation_expires_at=now()-interval '1 second' where job_id=$1",[f.job]);
  await value('select private.reconcile_delivery($1)',[f.job]);
  assert.equal(await value('select delivery_payment_status from public.pick_return_orders where job_id=$1',[f.job]),'Shop Pickup');
  assert.equal(Number(await value('select count(*) from public.jobs where id=$1',[f.job])),1);
  const state=await value<{job:string;eligible:boolean;awaiting_resolution:boolean}[]>('select public.delivery_queue_state()');
  assert.equal(state.find(s=>s.job===f.job)?.awaiting_resolution,false);assert.equal(state.find(s=>s.job===f.job)?.eligible,false);
 }finally{await db.exec('rollback');}
});

test('Delivery cutoff and driver interruption requeue for shop scheduling rather than silently allocating another route',async()=>{
 await db.exec('begin');
 try {
  const incidentJob=await driverReturnFixture('blocks-incident');
  await db.query('update public.unit_settings set shop_delivery_blocks_enabled=true where unit_id=$1',[unit]);
  const route=await value<string>('select route_id from public.pick_return_stops where id=$1',[incidentJob.stop]);
  const incident=await value<string>('select public.report_driver_incident($1)',[route]);
  await value("select public.resolve_driver_incident($1,'Rescheduled')",[incident]);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[incidentJob.job]),true);
  assert.equal(Number(await value("select count(*) from public.route_compensations where incident_id=$1 and job_id=$2 and amount=10",[incident,incidentJob.job])),1);
  const f=await readyReturn('blocks-cutoff');
  const days=await value<{date:string}[]>('select public.delivery_block_availability($1,now()::date+56)',[f.job]);await value('select public.assign_delivery_block($1,$2)',[f.job,days[0].date]);
  await db.query("update public.pick_return_orders set return_window_start=now()+interval '30 minutes',delivery_payment_method='Zelle' where job_id=$1",[f.job]);
  await value('select private.reconcile_delivery($1)',[f.job]);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[f.job]),true);
  assert.equal(await value('select return_window_start from public.pick_return_orders where job_id=$1',[f.job]),null);
  assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Scheduled'",[f.job])),0);
 }finally{await db.exec('rollback');}
});

test('Failed Delivery verification survives removal from the live block and requires every item before closure',async()=>{
 await db.exec('begin');try{
  const f=await driverReturnFixture('verify-failed-delivery');const route=await value<string>('select route_id from public.pick_return_stops where id=$1',[f.stop]);
  await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);await db.query("update public.pick_return_stops set return_wait_until=now()-interval '1 second' where id=$1",[f.stop]);await value("select public.return_driver_action($1,'not-home')",[f.stop]);
  assert.equal(await value('select status from public.failed_delivery_verifications where stop_id=$1',[f.stop]),'Pending');
  await blockReject(()=>value('select public.confirm_pick_return_route($1)',[route]),/verify each item/);
  await blockReject(()=>value("select public.verify_failed_delivery($1,'{}')",[f.stop]),/Verify|item/);
  const ids=await value<string[]>('select array_agg(id) from public.job_items where job_id=$1',[f.job]);await value('select public.verify_failed_delivery($1,$2::uuid[])',[f.stop,ids]);await value('select public.verify_failed_delivery($1,$2::uuid[])',[f.stop,ids]);
  assert.equal(await value('select status from public.failed_delivery_verifications where stop_id=$1',[f.stop]),'Verified');await value('select public.confirm_pick_return_route($1)',[route]);
 }finally{await db.exec('rollback');}
});

test('A documented loss moves the Job to Lost, retains driver and missing-item trace, and permits block closure without fabricated item checks',async()=>{
 await db.exec('begin');try{
  const f=await driverReturnFixture('lost-job');const route=await value<string>('select route_id from public.pick_return_stops where id=$1',[f.stop]);
  await value("select public.return_driver_action($1,'en-route')",[f.stop]);await value("select public.return_driver_action($1,'arrived')",[f.stop]);await db.query("update public.pick_return_stops set return_wait_until=now()-interval '1 second' where id=$1",[f.stop]);await value("select public.return_driver_action($1,'not-home')",[f.stop]);
  await blockReject(()=>value("select public.mark_failed_delivery_lost($1,'{}','')",[f.stop]),/Explain/);
  const loss=await value<string>("select public.mark_failed_delivery_lost($1,'{}','Item was not present when the driver returned to the shop.')",[f.stop]);
  assert.equal(await value('select is_lost from public.jobs where id=$1',[f.job]),true);assert.equal(await value('select status from public.failed_delivery_verifications where stop_id=$1',[f.stop]),'Lost');
  assert.equal(Number(await value("select count(*) from private.route_item_checks where stop_id=$1 and kind='Returned'",[f.stop])),0);
  assert.equal(await value("select public.mark_failed_delivery_lost($1,'{}','Repeat report')",[f.stop]),loss);
  const list=await value<{id:string;items:unknown[]}[]>('select public.lost_job_list()');assert.ok(list.find(l=>l.id===loss)?.items.length);
  assert.equal(await value('select private.delivery_queue_eligible($1)',[f.job]),false);await value('select public.confirm_pick_return_route($1)',[route]);
  await blockReject(()=>value("update public.jobs set is_lost=false where id=$1 returning id",[f.job]),/Lost/);
 }finally{await db.exec('rollback');}
});

test('Pickup block planning mirrors Delivery, preserves 8 AM–12 PM, and supports atomic reorder/removal',async()=>{
 await db.exec('begin');try{
  const a=await driverPickupFixture('pickup-block-a',350);const b=await driverPickupFixture('pickup-block-b',350);
  await db.query("update public.jobs set created_at=now()-interval '2 days' where id=$1",[a.job]);await db.query("update public.jobs set created_at=now()-interval '1 day' where id=$1",[b.job]);
  await db.query('update public.unit_settings set shop_pickup_blocks_enabled=true where unit_id=$1',[unit]);
  await db.query("update public.pick_return_stops set status='Cancelled' where id=any($1::uuid[])",[[a.stop,b.stop]]);
  await db.query("update public.pick_return_orders set pickup_status='Not Scheduled',pickup_window_start=null,pickup_window_end=null,pickup_eta=null where job_id=any($1::uuid[])",[[a.job,b.job]]);
  const dates=await value<{date:string;blocks:{capacity:number}[]}[]>('select public.pickup_block_availability($1,now()::date+400)',[a.job]);assert.ok(dates.length);assert.equal(dates[0].blocks[0].capacity,20);
  const route=await value<string>('select public.assign_pickup_block($1,$2)',[a.job,dates[0].date]);assert.equal(await value('select public.assign_pickup_block($1,$2)',[b.job,dates[0].date]),route);
  assert.equal(await value("select to_char(pickup_window_start at time zone 'America/Denver','HH24:MI') from public.pick_return_orders where job_id=$1",[a.job]),'08:00');
  const ids=await value<string[]>("select array_agg(id order by sequence) from public.pick_return_stops where route_id=$1 and status<>'Cancelled'",[route]);await value("select public.save_pickup_block($1,null,$2::uuid[],'{}',20,null)",[route,ids.slice().reverse()]);
  await value("select public.save_pickup_block($1,null,$2::uuid[],$3::uuid[],20,null)",[route,[ids[0]],[ids[1]]]);assert.equal(await value('select private.pickup_queue_eligible($1)',[b.job]),true);
 }finally{await db.exec('rollback');}
});

async function missPickupForRetry(suffix:string,option:"pickup_only"|"pickup_delivery"="pickup_delivery"){
 const f=await driverPickupFixture(suffix,600,option);await db.query('update public.unit_settings set shop_pickup_blocks_enabled=true where unit_id=$1',[unit]);
 await value("select public.pickup_driver_action($1,'en-route')",[f.stop]);await value("select public.pickup_driver_action($1,'arrived')",[f.stop]);await db.query("update public.pick_return_stops set pickup_wait_until=now()-interval '1 second' where id=$1",[f.stop]);await value("select public.pickup_driver_action($1,'pickup-miss')",[f.stop]);return f;
}
test('Missed Pickup & Delivery charges only Pickup Only, allocates manual payment exclusively to its retry invoice, and date choice returns to the shop queue',async()=>{
 await db.exec('begin');try{
  const f=await missPickupForRetry('paid-pickup-retry');const original=await value<number>('select fee_amount from public.pick_return_orders where job_id=$1',[f.job]);
  await value("select public.pickup_miss_choice($1,$2,'reschedule')",[f.job,f.token]);await value("select public.pickup_miss_choice($1,$2,'reschedule')",[f.job,f.token]);
  assert.equal(Number(await value('select count(*) from public.pickup_attempt_fees where job_id=$1',[f.job])),1);assert.equal(Number(await value('select amount from public.pickup_attempt_fees where job_id=$1',[f.job])),9.99);assert.equal(Number(original),19.99);
  const day=await value<string>('select (now()::date+700)::text');const a=await value<{day:string;slots:{eta:string}[]}>("select public.route_availability($1,'Pickup',$2,$3)",[f.job,day,f.token]);
  await blockReject(()=>value('select public.choose_pickup_retry_day($1,$2,$3)',[f.job,f.token,a.day]),/Confirm/);
  await blockReject(()=>value("select public.route_schedule($1,'Pickup',$2,$3,$4)",[f.job,a.day,a.slots[0].eta,f.token]),/new Pickup fee|shop will assign/);
  const baseBefore=await value<number>('select collected from public.sale_balances where job_id=$1',[f.job]);
  const req=await value<{id:string}>('select public.submit_pickup_retry_payment($1,\'Zelle\',gen_random_uuid())',[f.token]);await value('select public.confirm_payment_request($1)',[req.id]);
  assert.equal(Number(await value('select collected from public.sale_balances where job_id=$1',[f.job])),Number(baseBefore));assert.equal(await value('select private.pickup_retry_paid($1)',[f.job]),true);
  await value('select public.choose_pickup_retry_day($1,$2,$3)',[f.job,f.token,a.day]);assert.equal(await value('select private.pickup_queue_eligible($1)',[f.job]),true);assert.equal(Number(await value("select count(*) from public.pick_return_stops where job_id=$1 and status='Scheduled'",[f.job])),0);
  assert.equal(Number(await value('select fee_amount from public.pick_return_orders where job_id=$1',[f.job])),Number(original));
 }finally{await db.exec('rollback');}
});

test('Stripe TEST pickup retry confirmation pays only the retry sale and preserves pinned Utah tax',async()=>{
 await db.exec('begin');try{
  await db.query('update public.unit_settings set sales_tax_rate=7.45 where unit_id=$1',[unit]);const f=await missPickupForRetry('TEST-stripe-pickup-retry');await value("select public.pickup_miss_choice($1,$2,'reschedule')",[f.job,f.token]);
  assert.equal(Number(await value('select amount from public.pickup_attempt_fees where job_id=$1',[f.job])),10.73);assert.equal(Number(await value("select (s.tax_snapshot->>'tax_amount')::numeric from public.sales s join public.pickup_attempt_fees pf on pf.sale_id=s.transaction_id where pf.job_id=$1",[f.job])),0.74);
  const attempt=await value<string>('select gen_random_uuid()');await value('select public.prepare_pickup_retry_card($1,$2)',[f.token,attempt]);const again=await value<{attempt_id:string}>('select public.prepare_pickup_retry_card($1,gen_random_uuid())',[f.token]);assert.equal(again.attempt_id,attempt);await value("select public.attach_route_card_session($1,$2,'cs_test_pickup_retry')",[f.token,attempt]);const base=await value<number>('select collected from public.sale_balances where job_id=$1',[f.job]);
  await db.query("select set_config('request.jwt.claim.role','service_role',false)");await value("select public.confirm_logistics_card_payment($1,'cs_test_pickup_retry',10.73)",[attempt]);await value("select public.confirm_logistics_card_payment($1,'cs_test_pickup_retry',10.73)",[attempt]);
  assert.equal(await value('select private.pickup_retry_paid($1)',[f.job]),true);assert.equal(Number(await value('select collected from public.sale_balances where job_id=$1',[f.job])),Number(base));
 }finally{await db.exec('rollback');}
});

test('Unanswered combined Pickup expires once after 15 days and registers the delivery refund in existing Refunds without replay',async()=>{
 await db.exec('begin');try{
  const f=await missPickupForRetry('expiry-combined');await db.query("update public.pick_return_orders set fee_status='Pending Verification' where job_id=$1",[f.job]);const initial=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) select gen_random_uuid(),unit_id,job_id,'Zelle',fee_amount,'Pickup Fee' from public.pick_return_orders where job_id=$1 returning id",[f.job]);await value('select public.confirm_payment_request($1)',[initial]);await db.query("update public.pick_return_orders set pickup_miss_expires_at=now()-interval '1 second' where job_id=$1",[f.job]);
  await value('select private.reconcile_pickups()');await value('select private.reconcile_pickups()');assert.equal(await value('select status from public.jobs where id=$1',[f.job]),'Cancelled');
  assert.equal(Number(await value("select count(*) from public.refund_requests where job_id=$1 and source_kind='Pickup expiry'",[f.job])),1);assert.equal(Number(await value("select amount from public.refund_requests where job_id=$1 and source_kind='Pickup expiry'",[f.job])),9.99);assert.equal(await value("select status from public.refund_requests where job_id=$1 and source_kind='Pickup expiry'",[f.job]),'Pending');
  assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",['pickup-expiry-refund:'+f.stop])),1);
 }finally{await db.exec('rollback');}
});


test('Unanswered Pickup Only cancels after 15 days with no refund and preserves the nonrefundable initial fee',async()=>{
 await db.exec('begin');try{
  const f=await missPickupForRetry('expiry-pickup-only','pickup_only');
  await db.query("update public.pick_return_orders set fee_status='Pending Verification' where job_id=$1",[f.job]);
  const initial=await value<string>("insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose) select gen_random_uuid(),unit_id,job_id,'Zelle',fee_amount,'Pickup Fee' from public.pick_return_orders where job_id=$1 returning id",[f.job]);await value('select public.confirm_payment_request($1)',[initial]);
  await db.query("update public.pick_return_orders set pickup_miss_expires_at=now()-interval '1 second' where job_id=$1",[f.job]);
  await value('select private.reconcile_pickups()');await value('select private.reconcile_pickups()');
  assert.equal(await value('select status from public.jobs where id=$1',[f.job]),'Cancelled');
  assert.equal(Number(await value('select count(*) from public.refund_requests where job_id=$1',[f.job])),0);
  assert.equal(Number(await value('select collected from public.sale_balances where job_id=$1',[f.job])),9.99);
  assert.equal(Number(await value("select count(*) from public.notifications where dedupe_key=$1",['pickup-expiry-refund:'+f.stop])),0);
 }finally{await db.exec('rollback');}
});

 test("Staff login expires at four hours and expired or foreign sessions lose RBAC access", async()=>{
 const session=await value<{active:boolean;expires_at:string}>("select public.staff_session_state()");assert.equal(session.active,true);
 await db.query("update auth.sessions set created_at=now()-interval '4 hours' where id=$1",[admin]);
 try{assert.equal((await value<{active:boolean}>("select public.staff_session_state()")).active,false);assert.equal(await value("select private.staff_active($1)",[unit]),false);}
 finally{await db.query("update auth.sessions set created_at=now() where id=$1",[admin]);}
 await db.query("select set_config('request.jwt.claim.session_id','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false)");
 try{assert.equal((await value<{active:boolean}>("select public.staff_session_state()")).active,false);}
 finally{await db.query("select set_config('request.jwt.claim.session_id',$1,false)",[admin]);}
 });

test("Login attention is Owner/Manager-only and Job response clocks stop only after an audited response",async()=>{
 const customer=await createCustomer("Attention test","attention-test");
 const quote=await createQuote(customer.id);const token=await value<string>("select public.send_quote($1)",[quote]);
 const accepted=await acceptWithLogistics(token,{option_code:"dropoff_pickup"});const job=accepted.job_id;
 await db.query("update public.jobs set status='Issue / Review',work_stage='Issue Review' where id=$1",[job]);
 const load=()=>value<{eligible:boolean;items:{id:string;kind:string}[]}>("select public.urgent_login_attention()");
 const refund=await value<string>("insert into public.refund_requests(unit_id,job_id,amount,reason) values($1,$2,5,'Other') returning id",[unit,job]);
 const support=await supportWorker(()=>rpc("support_ingest",inboxMessage("urgent-in","urgent-thread")));

 let summary=await load();assert.equal(summary.eligible,true);assert.ok(summary.items.some(i=>i.kind==='problem'&&i.id===job));
 assert.ok(summary.items.some(i=>i.kind==='refund'&&i.id===refund));assert.ok(summary.items.some(i=>i.kind==='problem'&&i.id===support));
 await db.query("insert into public.support_messages(conversation_id,direction,sender_email,subject,body,delivery_status,sent_at) values($1,'Outbound','support@example.test','Response','Reply','Failed',now()+interval '1 second')",[support]);
 assert.ok((await load()).items.some(i=>i.id===support));
 await db.query("update public.support_messages set delivery_status='Sent' where conversation_id=$1 and direction='Outbound'",[support]);
 assert.equal((await load()).items.some(i=>i.id===support),false);
 await db.query("update public.refund_requests set status='Completed',processed_amount=amount where id=$1",[refund]);
 assert.equal((await load()).items.some(i=>i.id===refund),false);

 await db.query("update public.jobs set updated_at=now() where id=$1",[job]);
 await value("select public.record_issue_response($1)",[job]);
 summary=await load();assert.equal(summary.items.some(i=>i.kind==='problem'&&i.id===job),false);
 assert.equal(Number(await value("select count(*) from public.audit_log where entity_id=$1 and field='Customer issue response recorded'",[job])),1);
 await value("select public.record_issue_response($1)",[job]);
 assert.equal(Number(await value("select count(*) from public.audit_log where entity_id=$1 and field='Customer issue response recorded'",[job])),1);
 const employee=await addStaff(['Employee'],'attention-employee');await staffAs(employee,async()=>{assert.equal((await load()).eligible,false);});
 const managerRole=await value<string>("select public.rbac_save_role(null,'Manager',array['jobs.view'])");
 await value("select public.rbac_save_user($1,'attention-manager',true,array[$2]::uuid[])",[employee,managerRole]);
 await staffAs(employee,async()=>{assert.equal((await load()).eligible,true);});
 assert.equal(await value("select has_function_privilege('anon','public.urgent_login_attention()','execute')"),false);
});
