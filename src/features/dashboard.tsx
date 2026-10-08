import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { isConfigured } from "@/lib/supabase/server";
import { Heading, Panel, Metric, Empty, Table, Badge } from "@/components/ui";
export async function Dashboard() {
  const ready = isConfigured();
  const [summaries, review, activity] = ready
    ? await Promise.all([
        rows("finance_summary"),
        rows("review_items"),
        rows("recent_activity", { order: "created_at", limit: 10 }),
      ])
    : [[], [], []];
  const ctx = ready ? await context() : null;
  const { data: stats } = ctx
    ? await ctx.db.rpc("dashboard_stats", { p_unit: ctx.unit })
    : { data: null };
  const s = summaries[0];
  return (
    <>
      <Heading
        title="Todo bajo control."
        subtitle="Customers, work, and finances in one place."
      >
        <Link className="button" href="/app/quotes/new">
          + New Quote
        </Link>
        <Link className="button secondary" href="/app/finance">
          ToolTag Finance
        </Link>
      </Heading>
      <div className="grid">
        <Metric
          label="Trabajos activos"
          currency={false}
          value={stats?.active_jobs ?? 0}
          help={`${stats?.ready_jobs ?? 0} ready for delivery · ${stats?.issue_jobs ?? 0} under review`}
        />
        <Metric
          label="Cotizaciones pendientes"
          currency={false}
          value={stats?.pending_quotes ?? 0}
          help={`${stats?.accepted_quotes ?? 0} accepted`}
        />
        <Metric
          label="Main Account"
          value={s?.operating_balance}
          help="Balance attributed to ToolTag; this is not the full bank balance."
        />
      </div>
      <div className="grid two">
        <Panel title="Requires Attention">
          {review.length ? (
            review.slice(0, 8).map((r, i) => (
              <p key={i}>
                <Link href={r.path}>↗ {r.kind}</Link>
              </p>
            ))
          ) : (
            <Empty>
              {ready
                ? "All Clear — no hay pendientes."
                : "Conecta Supabase para cargar tus pendientes."}
            </Empty>
          )}
        </Panel>
        <Panel title="Clientes">
          <p className="muted">
            Empieza por la persona. Sus cotizaciones, trabajos y pagos quedan
            relacionados.
          </p>
          <div className="actions">
            <Link className="button secondary" href="/app/customers">
              Find Customer
            </Link>
            <Link className="button secondary" href="/app/customers/new">
              + New Customer
            </Link>
          </div>
        </Panel>
      </div>
      <Panel title="Ventas y cobros">
        <div className="grid">
          <Metric label="Ventas del mes" value={stats?.sales_month} />
          <Metric label="Cobrado este mes" value={stats?.collected_month} />
          <Metric label="Por cobrar" value={stats?.balance_due} />
        </div>
      </Panel>
      <Panel title="Actividad reciente">
        {activity.length ? (
          <Table headers={["Registro", "Cambio", "Fecha"]}>
            {activity.map((a) => (
              <tr key={a.id}>
                <td>
                  <Badge>{a.entity}</Badge>
                </td>
                <td>{a.changed_fields}</td>
                <td>
                  {new Date(a.created_at).toLocaleString("es-US", {
                    timeZone: "America/Denver",
                  })}
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
