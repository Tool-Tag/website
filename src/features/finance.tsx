import { randomUUID } from "node:crypto";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import {
  Heading,
  Panel,
  Table,
  Empty,
  Metric,
  Badge,
  FinanceTabs,
} from "@/components/ui";
import { Form } from "@/components/form";
import { MovementForm } from "@/components/movement-form";
import { money } from "@/lib/domain/money";
export async function Movement({
  saleId,
  type,
}: {
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
  return (
    <MovementForm
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
          label: `${s.code} · ${money(s.balance_due)} pending`,
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
}: {
  section?: string;
  id?: string;
  created?: string;
}) {
  const heading = (
    <>
      <Heading
        title="ToolTag Finance"
        subtitle="Sales, cash, and owner contributions, each in its proper place."
      >
        <Link className="button" href="/app/finance/transactions/new">
          + Record Transaction
        </Link>
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
              Funds attributed to ToolTag based on recorded transactions. This does not represent the full shared bank balance.
            </dd>
            <dt>Net Profit</dt>
            <dd>
              Sales minus customer refunds and net operating expenses. Collecting a sale does not generate revenue again. Equipment is shown separately; depreciation is not calculated.
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
              Operating Balance minus Owner Reimbursement Due. This V1 does not include additional accounts payable.
            </dd>
            <dt>Investment Recovery / Net Position</dt>
            <dd>
              Accumulated profit minus net equipment investment. This is an operating measure, not a tax return or a promise of capital recovery.
            </dd>
          </dl>
          <p>
            Receipt review follows the approved internal rule: receipts are required for $75 or more and always for lodging. Missing receipts may still be saved and reviewed.
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
    const docs = await rows("documents", {
      field: "transaction_id",
      value: id,
    });
    return (
      <>
        {heading}
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
              { name: "reason", label: "Reason for Change", required: true },
            ]}
          />
          <p className="muted">
            Amount corrections are recorded through refunds or revisions while preserving history.
          </p>
        </Panel>
        <Panel title="Receipts / Supporting Documents">
          {docs.map((d) => (
            <details key={d.id}>
              <summary>
                {d.type === "Payment Receipt" ? "Payment Receipt" : d.file_name}
              </summary>
              {d.drive_file_id ? (
                <a
                  href={`https://drive.google.com/file/d/${encodeURIComponent(d.drive_file_id)}/view`}
                >
                  Open Drive ↗
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
                    Paid Through This Receipt:{" "}
                    {money(d.content_snapshot.paid_to_date)}
                  </p>
                  <p>
                    Balance Due:{" "}
                    {money(d.content_snapshot.balance_remaining)}
                  </p>
                  <small>
                    Receipt saved. Email copy and Drive storage are pending integration.
                  </small>
                </div>
              ) : (
                <p className="muted">Document pending.</p>
              )}
            </details>
          ))}
          <Form
            operation="document"
            hidden={{ transaction_id: id, type: "Receipt" }}
            back={`/app/finance/transactions/${id}`}
            fields={[
              {
                name: "file_name",
                label: "File Name",
                required: true,
              },
              {
                name: "drive_file_id",
                label: "Existing Drive File ID",
                required: true,
              },
            ]}
            button="Link Receipt"
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
  if (section === "sales") {
    const sales = await rows("sale_balances");
    return (
      <>
        {heading}
        <Panel>
          {sales.length ? (
            <Table
              headers={["Sale", "Total", "Collected", "Pending", "Status"]}
            >
              {sales.map((s) => (
                <tr key={s.transaction_id}>
                  <td>
                    <Link href={`/app/finance/sales/${s.transaction_id}`}>
                      {s.code}
                    </Link>
                  </td>
                  <td>{money(s.amount)}</td>
                  <td>{money(s.collected)}</td>
                  <td>{money(s.balance_due)}</td>
                  <td>
                    <Badge>{s.status}</Badge>
                  </td>
                </tr>
              ))}
            </Table>
          ) : (
            <Empty>Sales are created when the Quote and terms are accepted.</Empty>
          )}
        </Panel>
      </>
    );
  }
  if (section === "expenses") {
    const expenses = await rows("expense_details");
    const saved = expenses.find((e) => e.transaction_id === created);
    return (
      <>
        {heading}
        {saved?.is_equipment && !saved.linked_asset_id && (
          <div className="notice success">
            Purchase saved.{" "}
            <Link href={`/app/equipment?expense=${created}`}>
              Create Linked Equipment →
            </Link>
          </div>
        )}
        <Panel title="Expenses">
          {expenses.length ? (
            <Table
              headers={[
                "Expense",
                "Amount",
                "Paid By",
                "Reimbursement Due",
                "Receipt",
              ]}
            >
              {expenses.map((e) => (
                <tr key={e.transaction_id}>
                  <td>
                    <Link
                      href={`/app/finance/transactions/${e.transaction_id}`}
                    >
                      {e.description}
                    </Link>
                    <br />
                    <small>{e.vendor}</small>
                  </td>
                  <td>{money(e.amount)}</td>
                  <td>{e.paid_by}</td>
                  <td>
                    {e.paid_by === "Owner" ? money(e.reimbursement_due) : "—"}
                  </td>
                  <td>{e.receipt_status}</td>
                </tr>
              ))}
            </Table>
          ) : (
            <Empty />
          )}
        </Panel>
        <details>
          <summary>Record Trip / Mileage</summary>
          <Form
            operation="mileage"
            fields={[
              { name: "date", label: "Date", type: "date", required: true },
              { name: "purpose", label: "Purpose", required: true },
              { name: "origin", label: "Origin", required: true },
              { name: "destination", label: "Destination", required: true },
              {
                name: "miles",
                label: "Miles",
                type: "number",
                required: true,
              },
              { name: "notes", label: "Notes" },
            ]}
            back="/app/finance/expenses"
          />
        </details>
      </>
    );
  }
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
            Save a version with figures and warnings. Previous versions are preserved. Review pending items first.
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
            Selected Method: {vehicle?.selected_method ?? "Fuel"} ·{" "}
            {vehicle?.year}
          </p>
          <p>
            Fuel History: {money(vehicle?.fuel_history)} · Miles registradas:{" "}
            {vehicle?.miles_history ?? 0}
          </p>
          <p>
            Amount considerado:{" "}
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
              <p>Close Warnings: {c.warnings.length}</p>
            </details>
          ))}
          {!closes.length && <Empty />}
        </Panel>
      </>
    );
  }
  if (section === "transactions") {
    const tx = await rows("transactions", { order: "transaction_date" });
    return (
      <>
        {heading}
        <Panel>
          {tx.length ? (
            <Table
              headers={["Date", "Transaction", "Type", "Amount", "Status"]}
            >
              {tx.map((t) => (
                <tr key={t.id}>
                  <td>{t.transaction_date}</td>
                  <td>
                    <Link href={`/app/finance/transactions/${t.id}`}>
                      {t.description}
                    </Link>
                  </td>
                  <td>{t.type}</td>
                  <td>{money(t.amount)}</td>
                  <td>
                    <Badge>{t.status}</Badge>
                  </td>
                </tr>
              ))}
            </Table>
          ) : (
            <Empty />
          )}
        </Panel>
      </>
    );
  }
  const s = (await rows("finance_summary"))[0];
  return (
    <>
      {heading}
      <div className="grid">
        {[
          ["operating_balance", "Main Account"],
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
            value={s?.[k]}
            help={
              k === "available_balance"
                ? "Attributed funds minus expenses still owed to the owner."
                : undefined
            }
          />
        ))}
      </div>
      <Panel>
        <Link href="/app/finance/about">How Each Number Is Calculated →</Link>
      </Panel>
    </>
  );
}
