import { can } from "@/lib/auth/permissions";
import { PermissionGate } from "@/components/permission-provider";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { isConfigured } from "@/lib/supabase/server";
import { Heading, Panel, Metric, Empty, Table, Badge } from "@/components/ui";
export async function Dashboard() {
  const ready = isConfigured();
  const ctx = ready ? await context() : null;
  const finance = Boolean(ctx && can(ctx.access,"payments.view"));
  const [summaries, review, activity] = ready
    ? await Promise.all([
        finance ? rows("finance_summary") : Promise.resolve([]),
        rows("review_items"),
        ctx?.access.owner ? rows("recent_activity", { order: "created_at", limit: 10 }) : Promise.resolve([]),
      ])
    : [[], [], []];
  const { data: stats } = ctx && finance
    ? await ctx.db.rpc("dashboard_stats", { p_unit: ctx.unit })
    : { data: null };
  const s = summaries[0];
  const [jobRows,quoteRows] = ctx ? await Promise.all([can(ctx.access,"jobs.view")?rows("jobs"):Promise.resolve([]),can(ctx.access,"quotes.view")?rows("quotes"):Promise.resolve([])]) : [[],[]];
  return (
    <>
      <Heading
        title="Todo bajo control."
        subtitle="Customers, work, and finances in one place."
      >
        <PermissionGate blocks={["quotes.manage"]}><Link className="button" href="/app/quotes/new">
          + New Quote
        </Link></PermissionGate>
        <PermissionGate blocks={["payments.view"]}><Link className="button secondary" href="/app/finance">
          ToolTag Finance
        </Link></PermissionGate>
      </Heading>
      <div className="grid">
        <Metric
          label="Active Jobs"
          currency={false}
          value={stats?.active_jobs ?? jobRows.filter(j=>j.status!=="Cancelled"&&j.work_stage!=="Closed").length}
          help={`${stats?.ready_jobs ?? 0} ready for delivery · ${stats?.issue_jobs ?? 0} in review`}
        />
        <Metric
          label="Pending Quotes"
          currency={false}
          value={stats?.pending_quotes ?? quoteRows.filter(q=>["Draft","Sent","Viewed","Agreement Pending"].includes(q.status)).length}
          help={`${stats?.accepted_quotes ?? 0} aceptadas`}
        />
        <PermissionGate blocks={["payments.view"]}><Metric
          label="Main Account"
          value={s?.operating_balance}
          help="Balance attributed to ToolTag; it is not the entire bank balance."
        /></PermissionGate>
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
                ? "All Clear — nothing pending."
                : "Connect Supabase to load items requiring attention."}
            </Empty>
          )}
        </Panel>
        <Panel title="Customers">
          <p className="muted">
            Start with the customer. Their Quotes, Jobs, and payments stay
            linked.
          </p>
          <div className="actions">
            <Link className="button secondary" href="/app/customers">
              Find Customer
            </Link>
            <PermissionGate owner><Link className="button secondary" href="/app/customers/new">
              + New Customer
            </Link></PermissionGate>
          </div>
        </Panel>
      </div>
      <PermissionGate blocks={["payments.view"]}><Panel title="Sales & Collections">
        <div className="grid">
          <Metric label="Sales This Month" value={stats?.sales_month} />
          <Metric label="Collected This Month" value={stats?.collected_month} />
          <Metric label="Outstanding Balance" value={stats?.balance_due} />
        </div>
      </Panel>
      </PermissionGate><PermissionGate owner><Panel title="Recent Activity">
        {activity.length ? (
          <Table headers={["Record", "Change", "Date"]}>
            {activity.map((a) => (
              <tr key={a.id}>
                <td>
                  <Badge>{a.entity}</Badge>
                </td>
                <td>{a.changed_fields}</td>
                <td>
                  {new Date(a.created_at).toLocaleString("en-US", {
                    timeZone: "America/Denver",
                  })}
                </td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty />
        )}
      </Panel></PermissionGate>
    </>
  );
}
