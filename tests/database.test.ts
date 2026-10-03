import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readdir, readFile } from "node:fs/promises";
const db = new PGlite();
const unit = "10000000-0000-0000-0000-000000000002";
const boft = "10000000-0000-0000-0000-000000000001";
const admin = "90000000-0000-0000-0000-000000000001";
let account: string,
  boftAccount: string,
  expenseCategory: string,
  assetCategory: string,
  equipmentCategory: string;
async function scalar(sql: string, args: unknown[] = []) {
  const r = await db.query<Record<string, unknown>>(sql, args);
  return Object.values(r.rows[0])[0] as string;
}
async function rpc(name: string, p: unknown) {
  return scalar(`select public.${name}($1::jsonb)`, [JSON.stringify(p)]);
}
async function move(
  type: string,
  amount: string,
  extra: Record<string, unknown> = {},
) {
  return rpc("record_movement", {
    unit_id: unit,
    account_id: account,
    type,
    amount,
    description: "Integration test",
    ...extra,
  });
}
async function summary() {
  return (
    await db.query<Record<string, string>>(
      "select * from public.finance_summary where unit_id=$1",
      [unit],
    )
  ).rows[0];
}
before(async () => {
  await db.exec(
    `create role anon; create role authenticated; create role service_role; create schema auth; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; create function auth.role() returns text language sql stable as $$ select current_setting('request.jwt.claim.role',true) $$; grant usage on schema auth to authenticated,anon,service_role; grant execute on all functions in schema auth to authenticated,anon,service_role;`,
  );
  for (const f of (await readdir("supabase/migrations")).sort())
    await db.exec(await readFile(`supabase/migrations/${f}`, "utf8"));
  await db.exec(
    `insert into auth.users values('${admin}'); insert into public.memberships select id,'${admin}','admin' from public.business_units; select set_config('request.jwt.claim.sub','${admin}',false);`,
  );
  account = await scalar("select id from public.accounts where unit_id=$1", [
    unit,
  ]);
  boftAccount = await scalar(
    "select id from public.accounts where unit_id=$1",
    [boft],
  );
  expenseCategory = await scalar(
    "select id from public.categories where name='Materials & Supplies'",
  );
  equipmentCategory = await scalar(
    "select id from public.categories where name='Equipment / Asset Purchase'",
  );
  assetCategory = await scalar(
    "select id from public.categories where name='Laser Equipment'",
  );
});
after(async () => {
  await db.close();
});
test("Owner injection is cash, not revenue; owner expense and reimbursement do not double count", async () => {
  await move("OWNER_INJECTION", "500.00");
  assert.equal((await summary()).net_profit, "0");
  await move("EXPENSE", "80.00", {
    category_id: expenseCategory,
    vendor: "Test vendor",
    paid_by: "Owner",
  });
  let s = await summary();
  assert.equal(Number(s.operating_balance), 500);
  assert.equal(Number(s.net_profit), -80);
  assert.equal(Number(s.owner_reimbursement_due), 80);
  await move("OWNER_DRAW", "30.00", { subtype: "Reimbursement" });
  s = await summary();
  assert.equal(Number(s.operating_balance), 470);
  assert.equal(Number(s.owner_reimbursement_due), 50);
  assert.equal(Number(s.net_profit), -80);
  await assert.rejects(
    () => move("OWNER_DRAW", "51.00", { subtype: "Reimbursement" }),
    /exceeds/,
  );
});
test("One allocation transfer changes neither physical cash nor profit", async () => {
  const before = Number(
    await scalar("select sum(operating_balance) from public.finance_summary"),
  );
  await move("INTER_UNIT_TRANSFER", "20.00", {
    destination_unit_id: boft,
    destination_account_id: boftAccount,
  });
  assert.equal(
    Number(
      await scalar("select sum(operating_balance) from public.finance_summary"),
    ),
    before,
  );
  assert.equal(Number((await summary()).net_profit), -80);
});
let quote: string, token: string, sale: string;
test("Quote and agreement produce exactly one job/sale; collection does not create revenue", async () => {
  const customer = await rpc("save_customer", {
    unit_id: unit,
    name: "Test Person",
    email: "test@example.test",
    phone: "5550001111",
    address: "Test address",
  });
  quote = await rpc("create_quote", {
    unit_id: unit,
    customer_id: customer,
    items: [
      {
        article: "Battery",
        quantity: 2,
        engraving_type: "Text",
        engraving_text: "BOFT",
        unit_price: "50.00",
      },
    ],
  });
  await assert.rejects(
    () => scalar("select public.send_quote($1)", [quote]),
    /Publish/,
  );
  await scalar("select public.publish_policy($1,$2,$3)", [
    unit,
    "TEST POLICY ONLY",
    "This text is test data only and is never published to a real customer.",
  ]);
  token = await scalar("select public.send_quote($1)", [quote]);
  await scalar("select public.accept_quote($1)", [token]);
  const j = await scalar("select public.accept_agreement($1,$2,$3,$4)", [
    token,
    "Test Person",
    "test@example.test",
    "5550001111",
  ]);
  assert.equal(
    await scalar("select public.accept_agreement($1,$2,$3,$4)", [
      token,
      "Test Person",
      "test@example.test",
      "5550001111",
    ]),
    j,
  );
  assert.equal(Number(await scalar("select count(*) from public.jobs")), 1);
  sale = await scalar(
    "select transaction_id from public.sales where job_id=$1",
    [j],
  );
  const profit = Number((await summary()).net_profit);
  await move("COLLECTION", "40.00", { sale_id: sale, payment_method: "Cash" });
  assert.equal(
    await scalar(
      "select status from public.sale_balances where transaction_id=$1",
      [sale],
    ),
    "Partially Paid",
  );
  await move("COLLECTION", "60.00", { sale_id: sale, payment_method: "Zelle" });
  assert.equal(
    await scalar(
      "select status from public.sale_balances where transaction_id=$1",
      [sale],
    ),
    "Paid",
  );
  assert.equal(Number((await summary()).net_profit), profit);
  await assert.rejects(
    () => move("COLLECTION", "0.01", { sale_id: sale, payment_method: "Cash" }),
    /exceeds/,
  );
});
test("Equipment expense links one asset and derives its financial facts", async () => {
  const e = await move("EXPENSE", "100.00", {
    category_id: equipmentCategory,
    vendor: "Equipment vendor",
    paid_by: "Business",
  });
  const p = {
    unit_id: unit,
    source_expense_id: e,
    origin: "Purchased",
    name: "Test laser",
    category_id: assetCategory,
  };
  const a = await rpc("create_asset", p);
  await assert.rejects(() => rpc("create_asset", p), /unlinked/);
  assert.equal(
    await scalar(
      "select linked_asset_id from public.expenses where transaction_id=$1",
      [e],
    ),
    a,
  );
  assert.equal(
    Number(
      await scalar(
        "select purchase_cost from public.asset_details where id=$1",
        [a],
      ),
    ),
    100,
  );
});
test("Closed-period changes require reason and reclose; older version preserved", async () => {
  const e = await move("EXPENSE", "10.00", {
    category_id: expenseCategory,
    vendor: "Test",
    paid_by: "Business",
    transaction_date: "2025-01-02",
  });
  await scalar("select public.close_month($1,'2025-01-01')", [unit]);
  await assert.rejects(
    () => move("OWNER_INJECTION", "10.00", { transaction_date: "2025-01-03" }),
    /Closed period/,
  );
  await rpc("update_transaction", {
    id: e,
    description: "Correction",
    reason: "Approved correction",
  });
  assert.equal(
    await scalar(
      "select status from public.monthly_closes where month='2025-01-01' and status<>'Superseded'",
    ),
    "Reclose Required",
  );
  await scalar("select public.close_month($1,'2025-01-01')", [unit]);
  assert.equal(
    Number(
      await scalar(
        "select count(*) from public.monthly_closes where month='2025-01-01'",
      ),
    ),
    2,
  );
});
test("RLS denies nonmember reads and direct writes; public token cannot list data", async () => {
  await db.exec(
    "set role authenticated; select set_config('request.jwt.claim.sub','90000000-0000-0000-0000-000000000099',false)",
  );
  assert.equal(
    Number(await scalar("select count(*) from public.transactions")),
    0,
  );
  await assert.rejects(
    () => move("OWNER_INJECTION", "5.00"),
    /access required/,
  );
  await assert.rejects(
    () =>
      db.exec(
        "insert into public.customers(unit_id,name,phone,email,address) values('" +
          unit +
          "','Bad','1','x','x')",
      ),
    /permission denied/,
  );
  await db.exec("reset role; set role anon");
  await assert.rejects(
    () => scalar("select count(*) from public.customers"),
    /permission denied/,
  );
  await assert.rejects(
    () => scalar("select public.public_quote($1)", ["invalid"]),
    /invalid/,
  );
  const q = await scalar("select public.public_quote($1)", [token]);
  assert.ok(q);
  await db.exec(
    `reset role; select set_config('request.jwt.claim.sub','${admin}',false)`,
  );
});
test("Partial refunds are capped by actual collection and need an override after 14 days", async () => {
  const payment = await move("COLLECTION", "25.00", {
    payment_method: "Cash",
    transaction_date: "2024-01-01",
  });
  await assert.rejects(
    () => move("REFUND", "5.00", { original_id: payment }),
    /14 days/,
  );
  await move("REFUND", "10.00", {
    original_id: payment,
    reason: "Approved exception",
  });
  await assert.rejects(
    () =>
      move("REFUND", "15.01", {
        original_id: payment,
        reason: "Approved exception",
      }),
    /eligible/,
  );
  await move("REFUND", "15.00", {
    original_id: payment,
    reason: "Approved exception",
  });
});
test("Viewer may read only their unit, cannot write, cannot see shared bank balance", async () => {
  const viewer = "90000000-0000-0000-0000-000000000002";
  await db.exec(
    `insert into auth.users values('${viewer}');insert into public.memberships values('${unit}','${viewer}','viewer');set role authenticated;select set_config('request.jwt.claim.sub','${viewer}',false);`,
  );
  assert.equal(
    Number(await scalar("select count(*) from public.physical_accounts")),
    0,
  );
  assert.equal(
    Number(await scalar("select count(*) from public.business_units")),
    1,
  );
  assert.ok(
    Number(await scalar("select count(*) from public.transactions")) > 0,
  );
  await assert.rejects(
    () => move("OWNER_INJECTION", "5.00"),
    /access required/,
  );
  await assert.rejects(
    () => scalar("select public.search_records($1,$2)", [boft, "test"]),
    /Access denied/,
  );
  await db.exec(
    `reset role;select set_config('request.jwt.claim.sub','${admin}',false)`,
  );
});
test("Documents mark a close as Documentation Updated without overwriting its snapshot", async () => {
  const t = await scalar(
    "select id from public.transactions where transaction_date='2025-01-02' limit 1",
  );
  const before = await scalar(
    "select snapshot::text from public.monthly_closes where month='2025-01-01' and status='Current'",
  );
  await rpc("add_document", {
    unit_id: unit,
    transaction_id: t,
    type: "Receipt",
    file_name: "test.jpg",
    drive_file_id: "test-drive-file-00001",
  });
  assert.equal(
    await scalar(
      "select status from public.monthly_closes where month='2025-01-01' and status<>'Superseded'",
    ),
    "Documentation Updated",
  );
  assert.equal(
    await scalar(
      "select snapshot::text from public.monthly_closes where month='2025-01-01' and status<>'Superseded'",
    ),
    before,
  );
});
test("Commercial revision preserves job and sale identities and prior agreement content", async () => {
  const originalJob = await scalar(
    "select job_id from public.sales where transaction_id=$1",
    [sale],
  );
  const newQ = await rpc("create_quote", {
    unit_id: unit,
    revises_id: quote,
    items: [
      {
        article: "Revised scope",
        quantity: 1,
        engraving_type: "Image / Logo",
        unit_price: "120.00",
      },
    ],
  });
  const tok = await scalar("select public.send_quote($1)", [newQ]);
  await scalar("select public.accept_quote($1)", [tok]);
  assert.equal(
    await scalar("select public.accept_agreement($1,$2,$3,$4)", [
      tok,
      "Test",
      "test@example.test",
      "5550001111",
    ]),
    originalJob,
  );
  assert.equal(Number(await scalar("select count(*) from public.sales")), 1);
  assert.equal(
    Number(
      await scalar(
        "select count(*) from public.sale_versions where sale_id=$1",
        [sale],
      ),
    ),
    2,
  );
  assert.equal(
    await scalar("select status from public.quotes where id=$1", [quote]),
    "Revised",
  );
  assert.equal(
    Number(
      await scalar(
        "select balance_due from public.sale_balances where transaction_id=$1",
        [sale],
      ),
    ),
    20,
  );
});
test("Receiving/completed evidence gate job transitions and missing messaging never starts deadline", async () => {
  const j = await scalar(
    "select job_id from public.sales where transaction_id=$1",
    [sale],
  );
  await assert.rejects(
    () => scalar("select public.advance_job($1,'start')", [j]),
    /receiving evidence/,
  );
  await rpc("add_document", {
    unit_id: unit,
    job_id: j,
    type: "Receiving Evidence",
    file_name: "receiving.jpg",
    drive_file_id: "test-receiving-00001",
  });
  await scalar("select public.advance_job($1,'start')", [j]);
  await assert.rejects(
    () => scalar("select public.advance_job($1,'ready')", [j]),
    /completed evidence/,
  );
  await rpc("add_document", {
    unit_id: unit,
    job_id: j,
    type: "Completed Evidence",
    file_name: "completed.jpg",
    drive_file_id: "test-completed-00001",
  });
  await scalar("select public.advance_job($1,'ready')", [j]);
  const link = await scalar("select public.advance_job($1,'deliver')", [j]);
  assert.equal(
    await scalar("select acceptance_deadline from public.jobs where id=$1", [
      j,
    ]),
    null,
  );
  await scalar("select public.confirm_completion_notified($1)", [j]);
  assert.ok(
    await scalar("select acceptance_deadline from public.jobs where id=$1", [
      j,
    ]),
  );
  const result = (await scalar("select public.public_completion($1,'accept')", [
    link,
  ])) as unknown as { status: string };
  assert.equal(result.status, "Completed");
  assert.equal(
    await scalar("select auto_closed_at from public.jobs where id=$1", [j]),
    null,
  );
});
test("Scheduled worker is restricted and monthly close is idempotent", async () => {
  await assert.rejects(
    () => scalar("select public.run_scheduled_tasks()"),
    /credentials/,
  );
  await db.exec(
    "select set_config('request.jwt.claim.role','service_role',false)",
  );
  await scalar("select public.run_scheduled_tasks()");
  const count = Number(
    await scalar("select count(*) from public.monthly_closes"),
  );
  await scalar("select public.run_scheduled_tasks()");
  assert.equal(
    Number(await scalar("select count(*) from public.monthly_closes")),
    count,
  );
  await db.exec(
    "select set_config('request.jwt.claim.role','authenticated',false)",
  );
});

test("Financial request retries are idempotent and cannot reuse a key with changed amount", async () => {
  const request_id = "80000000-0000-0000-0000-000000000001";
  const first = await move("OWNER_INJECTION", "3.00", { request_id });
  assert.equal(await move("OWNER_INJECTION", "3.00", { request_id }), first);
  await assert.rejects(
    () => move("OWNER_INJECTION", "4.00", { request_id }),
    /different information/,
  );
});

test("Quote marks persist and adaptation is calculated once per design by the database", async () => {
  const customer = await rpc("save_customer", {
    unit_id: unit,
    name: "Logo test",
    email: "logo@example.test",
    phone: "5559876543",
    address: "Test",
  });
  const item = {
    article: "Battery",
    quantity: 5,
    engraving_type: "Image / Logo",
    engraving_text: "Logo",
    unit_price: "10.00",
    marks: [
      { type: "Image / Logo", text: "", url: "https://example.com/a.png" },
    ],
  };
  const q = await rpc("create_quote", {
    unit_id: unit,
    customer_id: customer,
    items: [
      item,
      {
        ...item,
        quantity: 1,
        marks: [
          ...item.marks,
          { type: "Image / Logo", text: "", url: "https://example.com/b.png" },
        ],
      },
    ],
  });
  assert.equal(
    Number(
      await scalar(
        "select sum(quantity*unit_price) from public.quote_items where quote_id=$1",
        [q],
      ),
    ),
    66,
  );
  assert.equal(
    Number(
      await scalar(
        "select quantity from public.quote_items where quote_id=$1 and adaptation_fee",
        [q],
      ),
    ),
    2,
  );
  assert.equal(
    Number(
      await scalar(
        "select sum(jsonb_array_length(marks)) from public.quote_items where quote_id=$1",
        [q],
      ),
    ),
    3,
  );
  const revised = await rpc("create_quote", {
    unit_id: unit,
    revises_id: q,
    items: [item],
  });
  assert.equal(
    Number(
      await scalar(
        "select sum(quantity*unit_price) from public.quote_items where quote_id=$1",
        [revised],
      ),
    ),
    53,
  );
});
