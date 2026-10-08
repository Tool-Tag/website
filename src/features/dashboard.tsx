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
        subtitle="Customers, jobs, and finances in one place."
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
          label="Active Jobs"
          currency={false}
          value={stats?.active_jobs ?? 0}
          help={`${stats?.ready_jobs ?? 0} ready for delivery · ${stats?.issue_jobs ?? 0} under review`}
        />
        <Metric
          label="Pending Quotes"
          currency={false}
          value={stats?.pending_quotes ?? 0}
          help={`${stats?.accepted_quotes ?? 0} aceptadas`}
        />
        <Metric
          label="Main Account"
          value={s?.operating_balance}
          help="Saldo atribuido a ToolTag; no es todo el saldo del banco."
        />
      </div>
      <div className="grid two">
        <Panel title="Needs Attention">
          {review.length ? (
            review.slice(0, 8).map((r, i) => (
              <p key={i}>
                <Link href={r.path}>↗ {r.kind}</Link>
              </p>
            ))
          ) : (
            <Empty>
              {ready
                ? "All Clear — nothing needs attention."
                : "Connect Supabase to load items requiring attention."}
            </Empty>
          )}
        </Panel>
        <Panel title="Customers">
          <p className="muted">
            Empieza por la persona. Sus cotizaciones, trabajos y pagos quedan
            relacionados.
          </p>
          <div className="actions">
            <Link className="button secondary" href="/app/customers">
              Search Customer
            </Link>
            <Link className="button secondary" href="/app/customers/new">
              + New Customer
            </Link>
          </div>
        </Panel>
      </div>
      <Panel title="Sales & Collections">
        <div className="grid">
          <Metric label="Sales This Month" value={stats?.sales_month} />
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
