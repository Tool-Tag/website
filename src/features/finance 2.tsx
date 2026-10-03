import Link from "next/link";
import { rows } from "@/lib/domain/context";
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
      vendors={vendors.map((v) => v.name)}
      accounts={accounts.map((a) => ({ value: a.id, label: "Main Account" }))}
      categories={categories
        .filter((c) => c.kind === "expense" && c.active)
        .map((c) => ({ value: c.id, label: c.name }))}
      sales={sales
        .filter((s) => Number(s.balance_due) > 0)
        .map((s) => ({
          value: s.transaction_id,
          label: `${s.code} · ${money(s.balance_due)} pendiente`,
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
        subtitle="Ventas, efectivo y aportaciones, cada uno en su lugar."
      >
        <Link className="button" href="/app/finance/transactions/new">
          + Registrar movimiento
        </Link>
      </Heading>
      <FinanceTabs />
    </>
  );
  if (section === "about")
    return (
      <>
        {heading}
        <Panel title="Qué significa cada número">
          <dl>
            <dt>Operating Balance</dt>
            <dd>
              Fondos atribuidos a ToolTag según movimientos. No representa todo
              el saldo bancario compartido.
            </dd>
            <dt>Net Profit</dt>
            <dd>
              Ventas menos devoluciones de clientes y gastos operativos netos.
              Cobrar una venta no vuelve a generar ingreso. Equipo se muestra
              por separado; no calculamos depreciación.
            </dd>
            <dt>Equipment Investment</dt>
            <dd>
              Compras de equipo menos devoluciones correspondientes. Las
              donaciones son informativas.
            </dd>
            <dt>Owner Injection</dt>
            <dd>Aportaciones del dueño. Aumentan efectivo, no utilidad.</dd>
            <dt>Owner Reimbursement Due</dt>
            <dd>
              Gastos pagados por el dueño que aún no se le han reembolsado.
            </dd>
            <dt>Available Balance</dt>
            <dd>
              Operating Balance menos Owner Reimbursement Due. Esta V1 no
              incluye cuentas por pagar adicionales.
            </dd>
            <dt>Investment Recovery / Net Position</dt>
            <dd>
              Utilidad acumulada menos inversión neta en equipo. Es una medida
              operativa, no la declaración fiscal ni una promesa de recuperación
              del capital.
            </dd>
          </dl>
          <p>
            La revisión de comprobantes aplica la regla interna aprobada:
            requerido desde $75 y siempre en hospedaje. Se permite guardar y
            revisar faltantes.
          </p>
        </Panel>
      </>
    );
  if (section === "transactions" && id === "new")
    return (
      <>
        {heading}
        <Panel title="Nuevo movimiento">
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
                label: "Fecha",
                type: "date",
                value: t.transaction_date,
              },
              {
                name: "description",
                label: "Descripción",
                value: t.description,
              },
              {
                name: "status",
                label: "Estado",
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
            revisiones, conservando el historial.
          </p>
        </Panel>
        <Panel title="Comprobantes / recibos">
          {docs.map((d) => (
            <details key={d.id}>
              <summary>{d.file_name}</summary>
              {d.drive_file_id ? (
                <a
                  href={`https://drive.google.com/file/d/${encodeURIComponent(d.drive_file_id)}/view`}
                >
                  Abrir Drive ↗
                </a>
              ) : (
                <pre style={{ whiteSpace: "pre-wrap" }}>
                  {JSON.stringify(d.content_snapshot, null, 2)}
                </pre>
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
                label: "Nombre del archivo",
                required: true,
              },
              {
                name: "drive_file_id",
                label: "ID del archivo existente en Drive",
                required: true,
              },
            ]}
            button="Vincular comprobante"
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
            <Metric label="Venta" value={s.amount} />
            <Metric label="Cobrado" value={s.collected} />
            <Metric label="Por cobrar" value={s.balance_due} />
          </div>
          {s.job_id && (
            <Link href={`/app/jobs/${s.job_id}`}>Abrir trabajo →</Link>
          )}
        </Panel>
        {Number(s.balance_due) > 0 && (
          <Panel title="Registrar cobro">
            <Movement saleId={id} type="COLLECTION" />
          </Panel>
        )}
        <Panel title="Pagos y recibos">
          {tx
            .filter((t) => paymentIds.has(t.id))
            .map((t) => (
              <p key={t.id}>
                <Link href={`/app/finance/transactions/${t.id}`}>
                  {t.transaction_date} · {money(t.amount)} · Ver recibo →
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
              headers={["Venta", "Total", "Cobrado", "Pendiente", "Estado"]}
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
            <Empty>Las ventas se crean al aceptar cotización y términos.</Empty>
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
            Compra guardada.{" "}
            <Link href={`/app/equipment?expense=${created}`}>
              Crear el equipo vinculado →
            </Link>
          </div>
        )}
        <Panel title="Gastos">
          {expenses.length ? (
            <Table
              headers={[
                "Gasto",
                "Importe",
                "Pagado por",
                "Por reembolsar",
                "Comprobante",
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
          <summary>Registrar viaje / millas</summary>
          <Form
            operation="mileage"
            fields={[
              { name: "date", label: "Fecha", type: "date", required: true },
              { name: "purpose", label: "Propósito", required: true },
              { name: "origin", label: "Origen", required: true },
              { name: "destination", label: "Destino", required: true },
              {
                name: "miles",
                label: "Millas",
                type: "number",
                required: true,
              },
              { name: "notes", label: "Notas" },
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
        <Panel title="Revisión">
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
    const previous = new Date();
    previous.setUTCDate(1);
    previous.setUTCMonth(previous.getUTCMonth() - 1);
    return (
      <>
        {heading}
        <Panel title="Cerrar mes">
          <p className="muted">
            Guarda una versión con cifras y advertencias. Las versiones
            anteriores se conservan. Revisa primero los pendientes.
          </p>
          <Form
            operation="close"
            back="/app/finance/reports"
            fields={[
              {
                name: "month",
                label: "Primer día del mes a cerrar",
                type: "date",
                value: previous.toISOString().slice(0, 10),
                required: true,
              },
            ]}
            button="Cerrar mes ahora"
          />
        </Panel>
        <Panel title="Historial de cierres">
          {closes.map((c) => (
            <details key={c.id}>
              <summary>
                {c.month} · v{c.version} · {c.status}
              </summary>
              <p>
                Ingresos: {money(c.snapshot.revenue)} · Gastos:{" "}
                {money(c.snapshot.expenses)} · Equipo:{" "}
                {money(c.snapshot.equipment)}
              </p>
              <p>Advertencias al cierre: {c.warnings.length}</p>
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
              headers={["Fecha", "Movimiento", "Tipo", "Importe", "Estado"]}
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
                ? "Fondos atribuidos menos gastos pendientes de reembolsar al dueño."
                : undefined
            }
          />
        ))}
      </div>
      <Panel>
        <Link href="/app/finance/about">Cómo se calcula cada número →</Link>
      </Panel>
    </>
  );
}
