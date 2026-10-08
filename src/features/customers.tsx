import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Metric } from "@/components/ui";
import { Form, type Field } from "@/components/form";
import { money } from "@/lib/domain/money";
export const customerFields: Field[] = [
  { name: "name", label: "Person name", required: true },
  { name: "phone", label: "Phone", type: "tel", required: true },
  { name: "email", label: "Email", type: "email", required: true },
  { name: "address", label: "Address", required: true },
  { name: "company_name", label: "Company (optional)" },
  { name: "company_phone", label: "Company phone" },
  { name: "company_email", label: "Company email", type: "email" },
  { name: "company_address", label: "Company address" },
];
export async function Customers({ id, q }: { id?: string; q?: string }) {
  if (id === "new")
    return (
      <>
        <Heading
          title="New Customer"
          subtitle="We will review phone and email matches before saving."
        />
        <Panel>
          <Form operation="customer" fields={customerFields} />
        </Panel>
      </>
    );
  if (id) {
    const customer = (await rows("customers", { id }))[0];
    if (!customer) return <Empty>Customer not found.</Empty>;
    const flows = await rows("commercial_flows", {
      field: "customer_id",
      value: id,
    });
    const flowIds = new Set(flows.map((f) => f.id));
    const [allJobs, allQuotes, sales, docs] = await Promise.all([
      rows("jobs"),
      rows("quotes"),
      rows("sale_balances", { field: "customer_id", value: id }),
      rows("documents", { field: "customer_id", value: id }),
    ]);
    const ctx = await context();
    const { data: stats } = await ctx.db.rpc("customer_stats", { p_id: id });
    const jobs = allJobs.filter((j) => flowIds.has(j.flow_id)),
      quotes = allQuotes.filter((j) => flowIds.has(j.flow_id));
    return (
      <>
        <Heading title={customer.name} subtitle={customer.code}>
          <Link className="button" href={`/app/quotes/new?customer=${id}`}>
            + New Quote
          </Link>
        </Heading>
        <div className="grid">
          <Metric currency={false} label="Jobs" value={jobs.length} />
          <Metric label="Lifetime Sales" value={stats?.lifetime_sales} />
          <Metric label="Outstanding Balance" value={stats?.outstanding} />
        </div>
        <Panel title="Contacto">
          <p>
            {customer.email} · {customer.phone}
          </p>
          <p>{customer.address}</p>
          {customer.company_name && (
            <p>
              {customer.company_name} · {customer.company_email} ·{" "}
              {customer.company_phone}
            </p>
          )}
          <details>
            <summary>Editar datos</summary>
            <Form
              operation="customer"
              hidden={{ id }}
              fields={customerFields.map((f) => ({
                ...f,
                value: customer[f.name] ?? "",
              }))}
            />
          </details>
        </Panel>
        <div className="grid two">
          <Panel title="Quotes">
            {quotes.map((q) => (
              <p key={q.id}>
                <Link href={`/app/quotes/${q.id}`}>
                  {q.code} · v{q.revision} · {q.status}
                </Link>
              </p>
            ))}
            {!quotes.length && <Empty />}
          </Panel>
          <Panel title="Jobs">
            {jobs.map((j) => (
              <p key={j.id}>
                <Link href={`/app/jobs/${j.id}`}>
                  {j.code} · {j.status}
                </Link>
              </p>
            ))}
            {!jobs.length && <Empty />}
          </Panel>
        </div>
        <Panel title="Sales & Payments">
          {sales.map((s) => (
            <p key={s.transaction_id}>
              <Link href={`/app/finance/sales/${s.transaction_id}`}>
                {s.code} · {money(s.amount)} · {s.status}
              </Link>
            </p>
          ))}
          {!sales.length && <Empty />}
        </Panel>
        <Panel title="Documentos">
          {docs.map((d) => (
            <p key={d.id}>
              {d.drive_file_id ? (
                <a
                  href={`https://drive.google.com/file/d/${encodeURIComponent(d.drive_file_id)}/view`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {d.file_name} ↗
                </a>
              ) : (
                d.file_name
              )}
            </p>
          ))}
          {!docs.length && <Empty />}
        </Panel>
      </>
    );
  }
  const list = await rows("customers", { order: "created_at" });
  const term = (q ?? "").toLowerCase().trim();
  const filtered = list.filter((c) =>
    [c.name, c.email, c.phone, c.company_name, c.code].some((v) =>
      String(v ?? "")
        .toLowerCase()
        .includes(term),
    ),
  );
  const { db, unit } = await context();
  const { data: searchResults } = term
    ? await db.rpc("search_records", { p_unit: unit, p_query: term })
    : { data: null };
  return (
    <>
      <Heading
        title="Customers"
        subtitle="People, history, and related documents."
      >
        <Link className="button" href="/app/customers/new">
          + New Customer
        </Link>
      </Heading>
      <Panel>
        <form className="actions">
          <input
            style={{ maxWidth: 420 }}
            name="q"
            defaultValue={q}
            placeholder="Name, phone, email, or identifier"
            aria-label="Buscar"
          />
          <button>Buscar</button>
        </form>
      </Panel>
      <Panel>
        {filtered.length ? (
          <Table headers={["Customer", "Contact", "Company"]}>
            {filtered.map((c) => (
              <tr key={c.id}>
                <td>
                  <Link href={`/app/customers/${c.id}`}>{c.name}</Link>
                  <br />
                  <small>{c.code}</small>
                </td>
                <td>
                  {c.email}
                  <br />
                  {c.phone}
                </td>
                <td>{c.company_name ?? "—"}</td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty>No matches found.</Empty>
        )}
      </Panel>
      {searchResults?.length > 0 && (
        <Panel title="Related Records">
          {searchResults.map(
            (r: { id: string; label: string; path: string; kind: string }) => (
              <p key={r.id}>
                <Link href={r.path}>
                  {r.kind} · {r.label}
                </Link>
              </p>
            ),
          )}
        </Panel>
      )}
    </>
  );
}
