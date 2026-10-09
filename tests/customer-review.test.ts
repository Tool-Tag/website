import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { BaselineDatabase } from "./baseline-database";
import { readFile, readdir } from "node:fs/promises";
import {
  renderQuoteMail,
  prepareQuoteMail,
  type CommercialSnapshot,
} from "../src/lib/integrations/quote-mail";
const db = process.env.BASELINE_DATABASE_URL ? new BaselineDatabase() : new PGlite();
const unit = "10000000-0000-0000-0000-000000000002",
  admin = "90000000-0000-0000-0000-000000000001";
async function value<T = string>(
  sql: string,
  args: unknown[] = [],
): Promise<T> {
  const r = await db.query<Record<string, T>>(sql, args);
  return Object.values(r.rows[0])[0];
}
async function rpc(name: string, p: unknown) {
  return value(`select public.${name}($1::jsonb)`, [JSON.stringify(p)]);
}
before(async () => {
  if (!process.env.BASELINE_DATABASE_URL) {

  await db.exec(
    `create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create function auth.role() returns text language sql stable as $$ select current_setting('request.jwt.claim.role',true) $$;grant usage on schema auth to anon,authenticated,service_role;grant execute on all functions in schema auth to anon,authenticated,service_role;`,
  );
  for (const f of (await readdir("supabase/migrations-archive/pre-baseline")).sort())
    await db.exec(await readFile(`supabase/migrations-archive/pre-baseline/${f}`, "utf8"));
  }
  if (process.env.BASELINE_DATABASE_URL) {
    // Existing tests intentionally exercise the unpublished-Agreement gate in their own disposable database.
    await db.exec("SET session_replication_role=replica; DELETE FROM public.policies; SET session_replication_role=origin");
  }
  await db.exec(
    `insert into auth.users(id) values('${admin}');insert into public.memberships select id,'${admin}','admin' from public.business_units;select set_config('request.jwt.claim.sub','${admin}',false);`,
  );
});
after(() => db.close());
const items = [
  {
    article: "DeWalt Battery",
    quantity: 1,
    engraving_type: "Text",
    engraving_text: "MARTIN",
    unit_price: "30.00",
    paint_fill: true,
    colors: 1,
    paint_details: { mode: "single", color: "White", instructions: "" },
    marks: [
      { type: "Text", text: "MARTIN", url: "", location: "left side" },
      { type: "Text", text: "MARTIN", url: "", location: "right side" },
    ],
  },
  {
    article: "DeWalt Charger",
    quantity: 1,
    engraving_type: "Image / Logo",
    engraving_text: "ToolTag logo",
    unit_price: "20.00",
    paint_fill: false,
    marks: [
      {
        type: "Image / Logo",
        text: "",
        url: "https://example.test/logo.png",
        description: "ToolTag logo",
        location: "top",
      },
    ],
  },
];
let customer: string, q: string, token: string, job: string;
test("A–I: valid send requires Agreement; stable private link, calendar expiry, pinned policy and email snapshot", async () => {
  customer = await rpc("save_customer", {
    unit_id: unit,
    name: "Test Customer",
    email: "customer@example.test",
    phone: "5551234567",
    address: "Test",
  });
  q = await rpc("create_quote", {
    unit_id: unit,
    customer_id: customer,
    items,
  });
  assert.equal(
    await value("select status from public.quotes where id=$1", [q]),
    "Draft",
  );
  await assert.rejects(
    () => value("select public.send_quote($1)", [q]),
    /Publish/,
  );
  await value("select public.publish_policy($1,$2,$3)", [
    unit,
    "TEST ONLY",
    "Test-only placeholder supplied for isolated validation. Not approved legal text.",
  ]);
  await db.query("update public.customers set email='invalid' where id=$1", [
    customer,
  ]);
  await assert.rejects(
    () => value("select public.send_quote($1)", [q]),
    /usable email/,
  );
  await db.query(
    "update public.customers set email='customer@example.test' where id=$1",
    [customer],
  );
  token = await value("select public.send_quote($1)", [q]);
  assert.ok(token.length >= 64);
  assert.equal(
    await value("select status from public.quotes where id=$1", [q]),
    "Sent",
  );
  assert.equal(await value("select public.send_quote($1)", [q]), token);
  assert.equal(
    await value<boolean>(
      "select (expires_at at time zone 'America/Denver')=(sent_at at time zone 'America/Denver')+interval '7 days' from public.quotes where id=$1",
      [q],
    ),
    true,
  );
  await value("select public.publish_policy($1,$2,$3)", [
    unit,
    "TEST ONLY V2",
    "Second test placeholder which must not change the previous assigned Agreement.",
  ]);
  const snap = await value<CommercialSnapshot>(
    "select public.public_quote($1)",
    [token],
  );
  assert.equal(snap.policy.version, 1);
  assert.equal(Number(snap.total), 58);
  assert.equal(
    snap.items.reduce((n, i) => n + (i.marks?.length ?? 0), 0),
    3,
  );
  const mail = renderQuoteMail(
    snap,
    `https://tooltag.example.test/review/${token}`,
    "quote",
  );
  for (const text of [
    "Test",
    "DeWalt Battery",
    "2 engraving(s)",
    "left side",
    "right side",
    "top",
    "$58.00",
    "Valid Until",
    "Review & Accept Quote",
  ])
    assert.ok(mail.text.includes(text), text);
  assert.ok(!mail.html.includes(snap.policy.content));
  assert.equal(
    await value("select status from public.notifications where dedupe_key=$1", [
      `quote:${q}`,
    ]),
    "Pending Integration",
  );
});
test("J–P: both acknowledgments, atomic idempotent job/sale, contact snapshot, immutable records and audit", async () => {
  await db.exec("set role anon");
  await assert.rejects(
    () => value("select public.accept_quote($1)", [token]),
    /permission denied/,
  );
  await assert.rejects(
    () =>
      value("select public.accept_agreement($1,$2,$3,$4)", [
        token,
        "Test",
        "customer@example.test",
        "555",
      ]),
    /permission denied/,
  );
  await assert.rejects(
    () =>
      value("select public.accept_review($1,false,true,$2,$3,$4)", [
        token,
        "Test Customer",
        "customer@example.test",
        "5551234567",
      ]),
    /Both/,
  );
  await assert.rejects(
    () =>
      value("select public.accept_review($1,true,false,$2,$3,$4)", [
        token,
        "Test Customer",
        "customer@example.test",
        "5551234567",
      ]),
    /Both/,
  );
  job = await value("select public.accept_review($1,true,true,$2,$3,$4)", [
    token,
    "Test Customer",
    "customer@example.test",
    "5551234567",
  ]);
  assert.equal(
    await value("select public.accept_review($1,true,true,$2,$3,$4)", [
      token,
      "Test Customer",
      "customer@example.test",
      "5551234567",
    ]),
    job,
  );
  await db.exec("reset role");
  assert.equal(Number(await value("select count(*) from public.jobs")), 1);
  assert.equal(Number(await value("select count(*) from public.sales")), 1);
  assert.equal(
    await value("select status from public.jobs where id=$1", [job]),
    "Authorized",
  );
  const code = await value("select code from public.quotes where id=$1", [q]);
  assert.equal(
    await value("select code from public.jobs where id=$1", [job]),
    code.replace("TT-Q", "TT-J"),
  );
  assert.equal(
    await value("select code from public.sales where job_id=$1", [job]),
    code.replace("TT-Q", "TT-S"),
  );
  assert.equal(
    Number(
      await value(
        "select amount from public.transactions where id=(select transaction_id from public.sales where job_id=$1)",
        [job],
      ),
    ),
    58,
  );
  const snap = await value<CommercialSnapshot>(
    "select commercial_snapshot from public.agreements where quote_id=$1",
    [q],
  );
  assert.equal(snap.customer_email, "customer@example.test");
  assert.equal(snap.customer_phone, "5551234567");
  assert.equal(snap.revision, 1);
  assert.equal(snap.policy.version, 1);
  assert.equal(
    Number(
      await value(
        "select jsonb_array_length(approved_items) from public.sales where job_id=$1",
        [job],
      ),
    ),
    4,
  );
  await db.query(
    "update public.customers set name='Changed',email='changed@example.test' where id=$1",
    [customer],
  );
  assert.equal(
    (await value<CommercialSnapshot>("select public.public_quote($1)", [token]))
      .customer_name,
    "Test Customer",
  );
  await assert.rejects(
    () =>
      db.query(
        "update public.agreements set accepted_name='changed' where quote_id=$1",
        [q],
      ),
    /immutable/,
  );
  await assert.rejects(
    () =>
      db.query("update public.quote_items set unit_price=1 where quote_id=$1", [
        q,
      ]),
    /immutable/,
  );
  await assert.rejects(
    () => db.query("update public.quotes set notes='changed' where id=$1", [q]),
    /frozen/,
  );
  await assert.rejects(
    () =>
      db.query(
        "update public.policies set content='changed approved legal text'",
      ),
    /immutable/,
  );
  assert.ok(
    Number(
      await value("select count(*) from public.audit_log where entity_id=$1", [
        q,
      ]),
    ) > 0,
  );
  assert.equal(
    Number(
      await value(
        "select count(*) from public.notifications where dedupe_key=$1",
        [`drive-commercial:${q}`],
      ),
    ),
    1,
  );
  assert.equal(
    (
      await value<{ template: string }>(
        "select payload from public.notifications where dedupe_key=$1",
        [`agreement:${q}`],
      )
    ).template,
    "confirmation",
  );
});
test("Q–S: bad/expired links rejected, rotation invalidates old link, revisions preserve history and reuse job/sale", async () => {
  await assert.rejects(
    () => value("select public.public_quote('not-a-token')"),
    /invalid/,
  );
  const revision = await rpc("create_quote", {
    unit_id: unit,
    revises_id: q,
    items: [{ ...items[0], unit_price: "60.00" }],
  });
  let rt = await value("select public.send_quote($1)", [revision]);
  const previous = rt;
  rt = await value("select public.regenerate_quote_link($1)", [revision]);
  assert.notEqual(rt, previous);
  await assert.rejects(
    () => value("select public.public_quote($1)", [previous]),
    /invalid/,
  );
  assert.equal(
    Number(
      await value(
        "select amount from public.transactions where id=(select transaction_id from public.sales where job_id=$1)",
        [job],
      ),
    ),
    58,
  );
  assert.equal(
    await value("select public.accept_review($1,true,true,$2,$3,$4)", [
      rt,
      "Test Customer",
      "customer@example.test",
      "5551234567",
    ]),
    job,
  );
  assert.equal(Number(await value("select count(*) from public.jobs")), 1);
  assert.equal(Number(await value("select count(*) from public.sales")), 1);
  assert.equal(
    Number(await value("select count(*) from public.sale_versions")),
    2,
  );
  assert.equal(
    Number(
      (
        await value<CommercialSnapshot>("select public.public_quote($1)", [
          token,
        ])
      ).total,
    ),
    58,
  );
  assert.equal(
    await value("select status from public.quotes where id=$1", [q]),
    "Revised",
  );
  const expired = await rpc("create_quote", {
    unit_id: unit,
    customer_id: customer,
    items,
  });
  await db.query(
    "update public.quotes set policy_id=(select id from public.policies order by version desc limit 1),status='Sent',sent_at=now()-interval '8 days',expires_at=now()-interval '1 day' where id=$1",
    [expired],
  );
  await db.query(
    "insert into private.public_links(token_hash,unit_id,quote_id,expires_at) values(encode(sha256(convert_to('expired-test','UTF8')),'hex'),$1,$2,now()-interval '1 day')",
    [unit, expired],
  );
  await assert.rejects(
    () =>
      value(
        "select public.accept_review('expired-test',true,true,'Test','test@example.test','555')",
      ),
    /expired/,
  );
  await assert.rejects(
    () => value("select public.public_quote('expired-test')"),
    /expired/,
  );
});
test("Reminder becomes due two calendar days before expiry; no false delivery; worker idempotent", async () => {
  const reminderQuote = await rpc("create_quote", {
    unit_id: unit,
    customer_id: customer,
    items,
  });
  await value("select public.send_quote($1)", [reminderQuote]);
  assert.equal(
    await value<boolean>(
      "select (n.due_at at time zone 'America/Denver')=(q.expires_at at time zone 'America/Denver')-interval '2 days' from public.notifications n join public.quotes q on q.id=n.entity_id where n.dedupe_key=$1",
      [`quote-reminder:${reminderQuote}`],
    ),
    true,
  );
  await db.query(
    "update public.notifications set due_at=now()-interval '1 minute' where dedupe_key=$1",
    [`quote-reminder:${reminderQuote}`],
  );
  await db.exec(
    "select set_config('request.jwt.claim.role','service_role',false)",
  );
  await value("select public.run_scheduled_tasks()");
  await value("select public.run_scheduled_tasks()");
  assert.equal(
    await value<boolean>(
      "select (payload->>'due')::boolean from public.notifications where dedupe_key=$1",
      [`quote-reminder:${reminderQuote}`],
    ),
    true,
  );
  assert.equal(
    await value("select status from public.notifications where dedupe_key=$1", [
      `quote-reminder:${reminderQuote}`,
    ]),
    "Pending Integration",
  );
  assert.equal(
    Number(
      await value(
        "select count(*) from public.notifications where dedupe_key=$1",
        [`quote-reminder:${reminderQuote}`],
      ),
    ),
    1,
  );
  assert.equal(
    Number(
      await value("select count(*) from public.quotes where status='Expired'"),
    ),
    1,
  );
  await db.exec(
    "select set_config('request.jwt.claim.role','authenticated',false)",
  );
});
test("T: mail previews escape HTML and never send in test mode or without transport", async () => {
  const snapshot = await value<CommercialSnapshot>(
    "select commercial_snapshot from public.agreements where quote_id=$1",
    [q],
  );
  const mail = renderQuoteMail(
    { ...snapshot, customer_name: "<script>alert(1)</script>" },
    `https://tooltag.example.test/review/${token}`,
    "confirmation",
    "TT-J-2026-00001",
  );
  assert.ok(!mail.html.includes("<script>"));
  assert.ok(mail.subject.includes("TT-J-2026-00001"));
  let calls = 0;
  const transport = {
    async deliver() {
      calls++;
      return { providerId: "fake" };
    },
  };
  const preview = await prepareQuoteMail(
    { ...mail, from: "ToolTag <quotes@example.test>" },
    { mode: "test", transport, idempotencyKey: q },
  );
  assert.equal(preview.delivered, false);
  assert.equal(calls, 0);
  assert.equal(
    (await prepareQuoteMail(mail, { mode: "live", idempotencyKey: q }))
      .delivered,
    false,
  );
});

test("Additive upgrade preserves an already accepted legacy quote and its original contact/sale", async () => {
  const legacy = new PGlite();
  try {
    await legacy.exec(
      `create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;create function auth.role() returns text language sql stable as $$ select current_setting('request.jwt.claim.role',true) $$;grant usage on schema auth to anon,authenticated,service_role;grant execute on all functions in schema auth to anon,authenticated,service_role;`,
    );
    for (const f of (await readdir("supabase/migrations-archive/pre-baseline")).sort()) {
      if (f < "202610030002_customer_review.sql")
        await legacy.exec(await readFile(`supabase/migrations-archive/pre-baseline/${f}`, "utf8"));
    }
    await legacy.exec(
      `insert into auth.users(id) values('${admin}');insert into public.memberships select id,'${admin}','admin' from public.business_units;select set_config('request.jwt.claim.sub','${admin}',false);`,
    );
    await legacy.exec(`do $$ declare c uuid; q uuid; t text; begin
      c:=public.save_customer(jsonb_build_object('unit_id','${unit}','name','Legacy Customer','email','legacy@example.test','phone','5558761234','address','Test'));
      q:=public.create_quote(jsonb_build_object('unit_id','${unit}','customer_id',c,'items','[{"article":"Legacy battery","quantity":1,"engraving_type":"Text","engraving_text":"OLD","unit_price":"25.00"}]'::jsonb));
      perform public.publish_policy('${unit}','Legacy test policy','Legacy test content only. Not approved legal text.');
      t:=public.send_quote(q);perform public.accept_quote(t);perform public.accept_agreement(t,'Legacy Customer','legacy@example.test','5558761234');
      perform set_config('test.legacy_token',t,false);
      update public.customers set name='Changed later',email='changed@example.test' where id=c;
    end $$;`);
    const result = await legacy.query<{ token: string }>(
      "select current_setting('test.legacy_token') as token",
    );
    const oldToken = result.rows[0].token;
    const before = await legacy.query(
      "select id,quote_id,accepted_name,content_snapshot from public.agreements",
    );
    await legacy.exec(
      await readFile(
        "supabase/migrations-archive/pre-baseline/202610030002_customer_review.sql",
        "utf8",
      ),
    );
    const after = await legacy.query(
      "select id,quote_id,accepted_name,content_snapshot from public.agreements",
    );
    assert.deepEqual(before.rows, after.rows);
    const view = await legacy.query<{ q: CommercialSnapshot }>(
      "select public.public_quote($1) as q",
      [oldToken],
    );
    assert.equal(view.rows[0].q.customer_name, "Legacy Customer");
    assert.equal(view.rows[0].q.customer_email, "legacy@example.test");
    assert.equal(Number(view.rows[0].q.total), 25);
    assert.equal(view.rows[0].q.items[0].engraving_text, "OLD");
  } finally {
    await legacy.close();
  }
});

test("Paint is stored per engraving and charged once per colored piece", async () => {
  const marks = [{type: "Text", text: "A", location: "left", url: "", paint_fill: true, paint_details: {mode: "single", color: "Blue", instructions: ""}}, {type: "Text", text: "B", location: "right", url: "", paint_fill: true, paint_details: {mode: "single", color: "Gold", instructions: ""}}];
  const id = await rpc("create_quote", {unit_id: unit, customer_id: customer, items: [{article: "Battery", quantity: 3, engraving_type: "Text", unit_price: "10.00", marks}, {article: "Charger", quantity: 2, engraving_type: "Text", unit_price: "5.00", marks: [{type: "Text", text: "C", location: "top", url: "", paint_fill: false}]}]});
  assert.equal(await value("select sum(quantity*unit_price)::text from public.quote_items where quote_id=$1", [id]), "61.00");
  assert.equal(await value("select quantity from public.quote_items where quote_id=$1 and paint_fee", [id]), 3);
  assert.equal(await value("select marks->0->'paint_details'->>'color' from public.quote_items where quote_id=$1 and article='Battery'", [id]), "Blue");
});
