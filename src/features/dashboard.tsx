import {AttentionBands} from "@/components/attention-bands";
import {aggregateBands,classifyAttention,type AttentionRecord} from "@/lib/domain/urgent-attention";
import {dashboardWeekRange} from "@/lib/domain/dashboard-layout";
import {cents,decimal} from "@/lib/domain/money";
import {canAny} from "@/lib/auth/permissions";
import {Movement} from "@/features/finance";
import {activityDescription,activityRecordLabel} from "@/lib/domain/activity-description";
import { DashboardAttention } from "@/components/dashboard-attention";
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
  const [summaries, review] = ready
    ? await Promise.all([
        finance ? rows("finance_summary") : Promise.resolve([]),
        rows("review_items"),
      ])
    : [[], []];
  const activityResult=ctx?.access.owner
    ? await ctx.db.rpc("dashboard_recent_activity",{p_unit:ctx.unit})
    : {data:[],error:null};
  if(activityResult.error)console.error("Dashboard recent activity unavailable",{code:activityResult.error.code,message:activityResult.error.message});
  const activity=Array.isArray(activityResult.data)?activityResult.data as {id:string;entity:string;changed_fields:string;created_at:string}[]:[];
  const { data: stats } = ctx && finance
    ? await ctx.db.rpc("dashboard_stats", { p_unit: ctx.unit })
    : { data: null };
  const s = summaries[0];
  const [jobRows,quoteRows] = ctx ? await Promise.all([can(ctx.access,"jobs.view")?rows("jobs"):Promise.resolve([]),can(ctx.access,"quotes.view")?rows("quotes"):Promise.resolve([])]) : [[],[]];
  const range=dashboardWeekRange();
  const canRoutes=!!ctx&&canAny(ctx.access,["pr.routes.plan","pr.routes.live","pr.receiving","pr.returns"]);
  const [requestsResult,routeResult,urgentResult]=ctx?await Promise.all([
    can(ctx.access,"quotes.view")?ctx.db.rpc("get_tagged_attention"):Promise.resolve({data:[],error:null}),
    canRoutes?ctx.db.from("pick_return_routes").select("id,route_date").eq("unit_id",ctx.unit).eq("leg","Pickup").neq("status","Cancelled").is("confirmed_at",null).gte("route_date",range.today).order("route_date").order("block_number").limit(1):Promise.resolve({data:[],error:null}),
    ctx.db.rpc("urgent_login_attention"),
  ]):[{data:[],error:null},{data:[],error:null},{data:null,error:null}];
  const nextRoute=routeResult.data?.[0];
  const stopResult=ctx&&nextRoute?await ctx.db.from("pick_return_stops").select("id",{count:"exact",head:true}).eq("unit_id",ctx.unit).eq("route_id",nextRoute.id).neq("status","Cancelled"):{count:0,error:null};
  let collected=0n,collectionError=false;
  if(ctx&&finance){for(let offset=0;;offset+=500){const page=await ctx.db.from("transactions").select("id,amount").eq("unit_id",ctx.unit).eq("type","COLLECTION").neq("status","Voided").gte("transaction_date",range.monday).lte("transaction_date",range.today).order("id").range(offset,offset+499);if(page.error){collectionError=true;break;}for(const row of page.data)collected+=cents(String(row.amount));if(page.data.length<500)break;}}
  const bands=urgentResult.data?.eligible&&!urgentResult.error?aggregateBands(classifyAttention((urgentResult.data.items??[]) as AttentionRecord[])):null;
  const day=new Intl.DateTimeFormat("en-US",{timeZone:"America/Denver",weekday:"long",month:"short",day:"numeric",year:"numeric"}).format(new Date());
  return (
    <>
      <Heading title="Dashboard" subtitle={`${day} — here's what needs you today.`}/>
      <div className="hex-dashboard-metrics">
        <PermissionGate blocks={["jobs.view"]}><Metric label="Active jobs in pipeline" currency={false} value={stats?.active_jobs??jobRows.filter(j=>j.status!=="Cancelled"&&j.work_stage!=="Closed").length}/></PermissionGate>
        <PermissionGate blocks={["quotes.view"]}><Metric label="New Get Tagged requests" currency={false} value={requestsResult.error?"Unavailable":requestsResult.data?.length??0}/></PermissionGate>
        {canRoutes&&<Metric label="Stops in next pickup block" currency={false} value={routeResult.error||stopResult.error?"Unavailable":stopResult.count??0} help={nextRoute?new Intl.DateTimeFormat('en-US',{timeZone:'America/Denver',weekday:'long',month:'short',day:'numeric'}).format(new Date(nextRoute.route_date+'T12:00:00Z')):'No block scheduled'}/>}
        {finance&&<Metric label="Collected this week" currency={!collectionError} value={collectionError?'Unavailable':decimal(collected)}/>}
      </div>
      <section className="panel hex-daily-review"><header className="hex-panel-head hex-panel-head-row"><div><p className="eyebrow">Daily review</p><h2>Needs Attention</h2></div>{bands&&<span className="badge">Support · Refund · Lost</span>}</header>
        {bands&&<AttentionBands bands={bands}/>}
        {urgentResult.error&&<p className="notice">Urgent queues are temporarily unavailable.</p>}
        {review.length?<details className="hex-work-attention" open={!bands}><summary>Work needing attention ({review.length})</summary><DashboardAttention items={review.map(r=>({path:r.path,kind:r.kind}))}/></details>:!bands&&<Empty>{ready?'All Clear — nothing pending.':'Connect Supabase to load items requiring attention.'}</Empty>}
      </section>
      <Panel title="Quick actions"><div className="hex-quick-actions">
        <PermissionGate blocks={["quotes.manage"]}><Link className="button" href="/app/quotes/new">+ New Quote</Link></PermissionGate>
        <PermissionGate blocks={["quotes.view"]}><Link className="button secondary" href="/app/get-tagged">Review requests</Link></PermissionGate>
        <PermissionGate blocks={["support.inbox"]}><Link className="button secondary" href="/app/support">Support cases</Link></PermissionGate>
        {finance&&ctx&&can(ctx.access,"payments.record")&&<Movement modal/>}
      </div></Panel>
      <details className="hex-dashboard-more"><summary>More workspace details</summary>
      <div className="grid two">
        <Panel title="Quotes"><Metric label="Pending Quotes" currency={false} value={stats?.pending_quotes??quoteRows.filter(q=>["Draft","Sent","Viewed","Agreement Pending"].includes(q.status)).length} help={`${stats?.accepted_quotes??0} accepted`}/><PermissionGate blocks={["quotes.view"]}><Link className="button secondary" href="/app/quotes">View Quotes</Link></PermissionGate></Panel>

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
      <PermissionGate blocks={["payments.view"]}><Panel title="Sales & Collections"><Metric label="Main Account" value={s?.operating_balance} help="Balance attributed to ToolTag; it is not the entire bank balance."/>
        <div className="grid">
          <Metric label="Sales This Month" value={stats?.sales_month} />
          <Metric label="Collected This Month" value={stats?.collected_month} />
          <Metric label="Outstanding Balance" value={stats?.balance_due} />
        </div>
      </Panel>
      </PermissionGate><PermissionGate owner><Panel title="Recent Activity">
        {activityResult.error ? <p className="notice" role="status">Recent activity is temporarily unavailable. Refresh to retry.</p> : activity.length ? (
          <div className="recent-activity"><Table headers={["Record", "Change", "Date"]}>
            {activity.map((a) => (
              <tr key={a.id}>
                <td>
                  <Badge>{activityRecordLabel(a.entity)}</Badge>
                </td>
                <td>{activityDescription(a.entity,a.changed_fields)}</td>
                <td>
                  {new Date(a.created_at).toLocaleString("en-US", {
                    timeZone: "America/Denver",
                  })}
                </td>
              </tr>
            ))}
          </Table></div>
        ) : (
          <Empty />
        )}
      </Panel></PermissionGate>
      </details>
    </>
  );
}
