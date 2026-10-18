import {FinanceSalesList} from "@/features/finance-sales-list";
import {FinanceExpensesList} from "@/features/finance-expenses-list";
import type {FinanceSearch} from "@/lib/domain/finance-list";
import {FinanceQuarterRollover} from "@/components/finance-quarter-rollover";
import {FinanceTransactions} from "@/features/finance-transactions";
import {salesTaxSummary} from "@/lib/domain/sales-tax-summary";
import {SmsExpenseTrace} from "@/components/sms-expense-trace";
import { randomUUID } from "node:crypto";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import {
  Heading,
  Panel,
  Empty,
  Metric,
  Badge,
  FinanceTabs,
} from "@/components/ui";
import { Form } from "@/components/form";
import {MovementDialog} from "@/components/movement-dialog";
import { MovementForm } from "@/components/movement-form";
import { cents, decimal, money } from "@/lib/domain/money";
import { EvidenceUpload } from "@/components/evidence-upload";
import { legacyDriveUrl } from "@/lib/storage/files";
export async function Movement({
  saleId,
  type,
  modal=false,
}: {
  modal?: boolean;
  saleId?: string;
  type?: string;
}) {
  const [accounts, categories, sales, transactions, allAccounts, vendors] =
    await Promise.all([
      rows("accounts"),
      rows("categories"),
      rows("sale_balances"),
      rows("transactions"),
      rows("accounts", { unit: false }),
      rows("vendors"),
    ]);
  const options = (t: string) =>
    transactions
      .filter((x) => x.type === t && x.status !== "Voided")
      .map((x) => ({
        value: x.id,
        label: `${x.transaction_date} · ${x.description} · ${money(x.amount)}`,
      }));
  const Component=modal?MovementDialog:MovementForm;
  return (
    <Component
      requestId={randomUUID()}
      vendors={vendors.map((v) => v.name)}
      accounts={accounts.map((a) => ({ value: a.id, label: "Main Account" }))}
      categories={categories
        .filter((c) => c.kind === "expense" && c.active)
        .map((c) => ({ value: c.id, label: c.name }))}
      sales={sales
        .filter((s) => Number(s.balance_due) > 0)
        .map((s) => ({
          value: s.transaction_id,
          label: `${s.code} · ${money(s.balance_due)} due`,
        }))}
      expenses={options("EXPENSE")}
      collections={options("COLLECTION")}
      destinationAccounts={allAccounts
        .filter((a) => a.unit_id !== accounts[0]?.unit_id)
        .map((a) => ({ value: a.id, label: a.name }))}
      saleId={saleId}
      defaultType={type}
    />
  );
}
export async function Finance({
  section,
  id,
  created,
  search,
}: {
  section?: string;
  id?: string;
  created?: string;
  search?: FinanceSearch;
}) {
  const heading = (
    <>
      <Heading
        title="ToolTag Finance"
        subtitle="Sales, cash, and owner contributions, each recorded in the right place."
      >
        {(await context()).access.owner&&<Movement modal/>}
      </Heading>
      <FinanceTabs />
    </>
  );
  if (section === "about")
    return (
      <>
        {heading}
        <Panel title="What Each Number Means">
          <dl>
            <dt>Operating Balance</dt>
            <dd>
              Funds attributed to ToolTag based on recorded movements. It does not represent the
              full balance of the shared bank account.
            </dd>
            <dt>Expenses</dt>
            <dd>
              All recorded money leaving any ToolTag account, including expenses,
              customer refunds, owner reimbursements and withdrawals, and transfers
              out of ToolTag. Voided movements are excluded. Incoming refunds do
              not reduce this total; owner-paid expenses count only when reimbursed.
            </dd>
            <dt>Net Profit</dt>
            <dd>
              Registered sales revenue minus all outgoing funds shown in Expenses.
              Sales tax and owner contributions are not revenue. Customer refunds
              are counted once, within Expenses. Collecting a sale does not create
              income again.
            </dd>
            <dt>Sales Tax</dt>
            <dd>
              Tax on registered sales, less the tax portion of customer refunds,
              using the tax amounts recorded with each transaction. The current
              quarter follows the annual start dates configured in Settings → Prices
              and uses Denver time. Accumulated tax retains the full history;
              this is not a balance of tax payments or filings.
            </dd>
            <dt>Equipment Investment</dt>
            <dd>
              Equipment purchases minus related refunds. Donations are informational.
            </dd>
            <dt>Owner Injection</dt>
            <dd>Owner contributions. They increase cash, not profit.</dd>
            <dt>Owner Reimbursement Due</dt>
            <dd>
              Expenses paid by the owner that have not yet been reimbursed.
            </dd>
            <dt>Available Balance</dt>
            <dd>
              Operating Balance minus Owner Reimbursement Due. This V1 does not
              include additional accounts payable.
            </dd>
            <dt>Investment Recovery / Net Position</dt>
            <dd>
              Accumulated profit minus net investment in equipment. This is an
              operating measure, not a tax return or a promise of capital recovery.
            </dd>
          </dl>
          <p>
            Receipt review applies the approved internal rule:
            required at $75 and above. Upload a receipt image before saving any expense of $75 or more.
          </p>
        </Panel>
      </>
    );
  if (section === "transactions" && id === "new")
    return (
      <>
        {heading}
        <Panel title="New Transaction">
          <Movement />
        </Panel>
      </>
    );
  if (section === "transactions" && id) {
    const t = (await rows("transactions", { id }))[0];
    if (!t) return <Empty />;
    const smsExpense = t.type==="EXPENSE"?(await rows("expenses",{field:"transaction_id",value:id}))[0]:null;
    const docs = await rows("documents", {
      field: "transaction_id",
      value: id,
    });
    return (
      <>
        {heading}
        {smsExpense?.sms_cost_snapshot&&<SmsExpenseTrace snapshot={smsExpense.sms_cost_snapshot}/> }
        <Panel title={t.description}>
          <p>
            {t.type} · {t.transaction_date} · {money(t.amount)} · {t.status}
          </p>
          <Form
            operation="update-transaction"
            hidden={{ id }}
            back={`/app/finance/transactions/${id}`}
            fields={[
              {
                name: "transaction_date",
                label: "Date",
                type: "date",
                value: t.transaction_date,
              },
              {
                name: "description",
                label: "Description",
                value: t.description,
              },
              {
                name: "status",
                label: "Status",
                value: t.status,
                options: ["Active", "Archived", "Voided"].map((value) => ({
                  value,
                  label: value,
                })),
              },
              { name: "reason", label: "Motivo del cambio", required: true },
            ]}
          />
          <p className="muted">
            Las correcciones de importes se registran mediante devoluciones o
            revisions while preserving history.
          </p>
        </Panel>
        <Panel title="Comprobantes / recibos">
          {docs.map((d) => (
            <details key={d.id}>
              <summary>
                {d.type === "Payment Receipt" ? "Payment Receipt" : d.file_name}
              </summary>
              {d.storage_status === "stored" ? (
                <a
                  href={`/app/documents/${d.id}/download`}
                  target="_blank"
                  rel="noreferrer"
                >
                  View stored file ↗
                </a>
              ) : d.drive_file_id ? (
                <a
                  href={legacyDriveUrl(d.drive_file_id)}
                  target="_blank"
                  rel="noreferrer"
                >
                  Legacy Drive reference ↗
                </a>
              ) : d.content_snapshot ? (
                <div className="panel">
                  <h3>
                    {d.content_snapshot.balance_remaining === 0
                      ? "Paid · Final Receipt"
                      : "Payment Receipt"}
                  </h3>
                  <p>
                    Sale:{" "}
                    {d.content_snapshot.sale_code ?? "Unlinked Collection"}
                  </p>
                  <p>
                    Received: {money(d.content_snapshot.amount)} ·{" "}
                    {d.content_snapshot.payment_method} ·{" "}
                    {d.content_snapshot.date}
                  </p>
                  <p>Sale Total: {money(d.content_snapshot.sale_total)}</p>
                  <p>
                    Paid through this receipt:{" "}
                    {money(d.content_snapshot.paid_to_date)}
                  </p>
                  <p>
                    Balance due:{" "}
                    {money(d.content_snapshot.balance_remaining)}
                  </p>
                  <small>Receipt record saved in ToolTag.</small>
                </div>
              ) : (
                <p className="muted">Document unavailable.</p>
              )}
            </details>
          ))}
          <EvidenceUpload
            config={{
              transactionId: id,
              photoOnly: true,
              type: "Receipt",
              defaultVisibility: "internal",
            }}
            button="Upload Receipt"
          />
        </Panel>
      </>
    );
  }
  if (section === "sales" && id) {
    const s = (
      await rows("sale_balances", { field: "transaction_id", value: id })
    )[0];
    if (!s) return <Empty />;
    const payments = await rows("collections", { field: "sale_id", value: id });
    const tx = await rows("transactions");
    const paymentIds = new Set(payments.map((p) => p.transaction_id));
    return (
      <>
        {heading}
        <Panel title={s.code}>
          <Badge>{s.status}</Badge>
          <div className="grid">
            <Metric label="Sale" value={s.amount} />
            <Metric label="Collected" value={s.collected} />
            <Metric label="Balance Due" value={s.balance_due} />
          </div>
          {s.job_id && (
            <Link href={`/app/jobs/${s.job_id}`}>Open Job →</Link>
          )}
        </Panel>
        {Number(s.balance_due) > 0 && (
          <Panel title="Record Collection">
            <Movement saleId={id} type="COLLECTION" />
          </Panel>
        )}
        <Panel title="Payments & Receipts">
          {tx
            .filter((t) => paymentIds.has(t.id))
            .map((t) => (
              <p key={t.id}>
                <Link href={`/app/finance/transactions/${t.id}`}>
                  {t.transaction_date} · {money(t.amount)} · View Receipt →
                </Link>
              </p>
            ))}
        </Panel>
      </>
    );
  }
  if (section === "sales") return <FinanceSalesList header={heading} search={search}/>;
  if (section === "expenses") return <FinanceExpensesList header={heading} search={search} created={created}/>;
  if (section === "review") {
    const list = await rows("review_items");
    return (
      <>
        {heading}
        <Panel title="Review">
          {list.length ? (
            list.map((r, i) => (
              <p key={i}>
                <Link href={r.path}>↗ {r.kind}</Link>
              </p>
            ))
          ) : (
            <Empty>All Clear</Empty>
          )}
        </Panel>
      </>
    );
  }
  if (section === "reports") {
    const closes = await rows("monthly_closes", { order: "created_at" });
    const ctx = await context();
    const { data: vehicle } = await ctx.db.rpc("vehicle_report", {
      p_unit: ctx.unit,
      p_year: new Date().getFullYear(),
    });
    const previous = new Date();
    previous.setUTCDate(1);
    previous.setUTCMonth(previous.getUTCMonth() - 1);
    return (
      <>
        {heading}
        <Panel title="Close Month">
          <p className="muted">
            Save a version with figures and warnings. Previous versions
            are preserved. Review pending items first.
          </p>
          <Form
            operation="close"
            back="/app/finance/reports"
            fields={[
              {
                name: "month",
                label: "First Day of Month to Close",
                type: "date",
                value: previous.toISOString().slice(0, 10),
                required: true,
              },
            ]}
            button="Close Month Now"
          />
        </Panel>
        <Panel title="Vehicle · Annual Analysis">
          <p>
            Selected method: {vehicle?.selected_method ?? "Fuel"} ·{" "}
            {vehicle?.year}
          </p>
          <p>
            Fuel history: {money(vehicle?.fuel_history)} · Miles recorded:{" "}
            {vehicle?.miles_history ?? 0}
          </p>
          <p>
            Amount considered:{" "}
            {vehicle?.selected_amount == null
              ? "Set the mileage rate in Settings"
              : money(vehicle.selected_amount)}
          </p>
          <small>
            Only one method is used. Both histories are preserved.
          </small>
        </Panel>
        <Panel title="Close History">
          {closes.map((c) => (
            <details key={c.id}>
              <summary>
                {c.month} · v{c.version} · {c.status}
              </summary>
              <p>
                Revenue: {money(c.snapshot.revenue)} · Expenses:{" "}
                {money(c.snapshot.expenses)} · Equipment:{" "}
                {money(c.snapshot.equipment)}
              </p>
              <p>Warnings at Close: {c.warnings.length}</p>
            </details>
          ))}
          {!closes.length && <Empty />}
        </Panel>
      </>
    );
  }
  if (section === "transactions") return <FinanceTransactions search={search} header={heading}/>;
  const { db, unit } = await context();
  const [summary,quarterSettings] = await Promise.all([rows("finance_summary"),db.rpc("tax_quarter_dates")]);
  if(quarterSettings.error || !quarterSettings.data)throw new Error("Unable to load Sales Tax reporting dates.");
  const s = summary[0];
  // Read every ledger effect, across all TT accounts, without rows()'s
  // 200-record cap. Voided movements are excluded by the existing ledger.
  // Positive revenue represents registered sales, excluding sales tax. Negative
  // revenue (customer refunds) is not deducted again: it is already an outflow.
  const taxTransactions = new Map<string, {type:string;amount:string}>();
  for (let offset = 0; ; offset += 500) {
    const {data,error} = await db.from("transactions").select("id,type,amount")
      .eq("unit_id",unit).neq("status","Voided").in("type",["SALE","REFUND"])
      .order("id").range(offset,offset+499);
    if (error) throw new Error(`Unable to load recorded sales tax: ${error.message}`);
    for (const row of data ?? []) taxTransactions.set(row.id,{type:row.type,amount:String(row.amount)});
    if ((data?.length ?? 0) < 500) break;
  }
  const taxRecords: Parameters<typeof salesTaxSummary>[0] = [];
  let outgoingCents = 0n;
  let salesCents = 0n;
  for (let offset = 0; ; offset += 500) {
    const { data, error } = await db.from("financial_effects")
      .select("id,cash,revenue,transaction_date").eq("unit_id", unit)
      .order("id").range(offset, offset + 499);
    if (error) throw new Error(`Unable to load ToolTag financial totals: ${error.message}`);
    for (const effect of data ?? []) {
      const cash = String(effect.cash);
      const revenue = String(effect.revenue);
      const transaction = taxTransactions.get(effect.id);
      if (transaction) taxRecords.push({...transaction,revenue,date:effect.transaction_date});
      if (cash.startsWith("-")) outgoingCents += cents(cash.slice(1));
      if (!revenue.startsWith("-")) salesCents += cents(revenue);
    }
    if ((data?.length ?? 0) < 500) break;
  }
  const salesTax = salesTaxSummary(taxRecords,new Date(),quarterSettings.data);
  const totalExpenses = decimal(outgoingCents);
  const netProfitCents = salesCents - outgoingCents;
  const netProfit = decimal(netProfitCents);
  const netProfitTone = netProfitCents > 0n ? "positive" : netProfitCents < 0n ? "negative" : undefined;
  return (
    <>
      {heading}
      <div className="grid">
        {[
          ["operating_balance", "Main Account"],
          ["expenses", "Expenses"],
          ["net_profit", "Net Profit"],
          ["equipment_investment", "Equipment Investment"],
          ["owner_injection", "Owner Injection"],
          ["owner_reimbursement_due", "Owner Reimbursement Due"],
          ["available_balance", "Available Balance"],
          ["net_position", "Investment Recovery / Net Position"],
        ].map(([k, l]) => (
          <Metric
            key={k}
            label={l}
            tone={k === "net_profit" ? netProfitTone : undefined}
            value={k === "expenses" ? totalExpenses : k === "net_profit" ? netProfit : s?.[k]}
            help={
              k === "expenses"
                ? "All recorded outgoing money across every ToolTag account; voided movements excluded."
                : k === "net_profit"
                ? "Registered sales revenue minus total outgoing funds. Sales tax and owner contributions are excluded from revenue."
                : k === "available_balance"
                ? "Attributed funds minus expenses still owed to the owner."
                : undefined
            }
          />
        ))}
        <FinanceQuarterRollover starts={quarterSettings.data} currentStart={salesTax.quarter.start}/>
        <div className="metric" aria-label="Sales Tax">
          <span className="muted">Sales Tax</span>
          <section aria-label="Accumulated sales tax"><small>Total accumulated</small><strong>{money(salesTax.accumulated)}</strong></section>
          <section aria-label="Current quarter sales tax"><small>Current quarter · {salesTax.quarter.label}</small><strong>{money(salesTax.current)}</strong></section>
          <small>Registered sales tax, less customer refund tax. Current quarter resets automatically on the configured start dates (Denver time).</small>
        </div>
      </div>
      <Link className="button secondary" href="/app/finance/about">
        How Each Number Is Calculated →
      </Link>
    </>
  );
}
