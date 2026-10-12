import { can, canAny } from "@/lib/auth/permissions";
import { RouteOperator } from "@/components/route-operator";
import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Heading, Panel } from "@/components/ui";
import { ShopItemVerification } from "@/components/shop-item-verification";
import { RouteItemVerification } from "@/components/route-item-verification";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { RouteCalendar } from "@/components/route-calendar";
import { StatusRefresh } from "@/components/status-refresh";
import { Form } from "@/components/form";
import { denverDateTime, TOOLTAG_TIMEZONE } from "@/lib/domain/time";

export const dynamic = "force-dynamic";

export default async function ShopPickReturn({ searchParams }: {
  searchParams: Promise<{ view?: string; date?: string }>;
}) {
  const { db, unit, access } = await requirePermission("pr.routes.plan","pr.routes.live","pr.receiving","pr.returns","pr.reschedule");
  const operators = can(access,"pr.routes.plan") ? (await db.rpc("route_operators")).data ?? [] : [];
  const query = await searchParams;
  const views = ["receiving", "returns", "routes", "pending", "rescheduled"];
  const view = views.includes(query.view ?? "") ? query.view! : "receiving";
  const date = /^\d{4}-\d{2}-\d{2}$/.test(query.date ?? "") ? query.date! : new Intl.DateTimeFormat("en-CA", { timeZone: TOOLTAG_TIMEZONE }).format(new Date());
  // Paginate operational queues: an older unresolved job must never disappear behind a row limit.
  async function load(table: string) {
    const records = [];
    for (let offset = 0; ; offset += 500) {
      const { data, error } = await db.from(table).select("*").eq("unit_id", unit).order("id").range(offset, offset + 499);
      if (error) throw new Error(`Could not load shop ${table}`);
      records.push(...(data ?? []));
      if ((data?.length ?? 0) < 500) return records;
    }
  }
  const [orders, jobs, items, routes, stops, documents, flows, customers] = await Promise.all([
    load("pick_return_orders"), load("jobs"), load("job_items"), load("pick_return_routes"),
    load("pick_return_stops"), load("documents"), load("commercial_flows"), load("customers"),
  ]);
  const openOrders = orders.filter(order => jobs.some(job => job.id === order.job_id && !["Cancelled", "Closed"].includes(job.status)));
  const pieces = (job: string) => items.filter(item => item.job_id === job && item.stage !== "Cancelled");
  const receiving = openOrders.filter(order => order.pickup_status === "Picked Up" && pieces(order.job_id).some(item => !item.shop_received_at));
  const returnRoutes = routes.filter(route => route.leg === "Return" && !route.confirmed_at && route.status !== "Cancelled" && stops.some(stop => stop.route_id === route.id && stop.status === "Failed"));
  const pending = openOrders.filter(order => !order.returned_at && (order.return_reservation_expires_at || order.delivery_payment_status === "Shop Pickup"));
  const pickupQueue = openOrders.filter(order => ["Failed", "Not Scheduled"].includes(order.pickup_status));
  const deliveryQueue = openOrders.filter(order => order.production_ready_at && ["Not Scheduled", "Failed", "Not Ready", "Delivery In Progress"].includes(order.return_status) && !order.return_window_start && !order.return_reservation_stop_id && order.delivery_payment_status !== "Shop Pickup");
  const jobTitle = (id: string) => {
    const job = jobs.find(row => row.id === id);
    const flow = flows.find(row => row.id === job?.flow_id);
    const customer = customers.find(row => row.id === flow?.customer_id);
    return <Link href={`/app/jobs/${id}`}>{job?.code ?? "Job"} · {customer?.name ?? "Customer"}</Link>;
  };
  const channels = await Promise.all(routes.filter(route => !route.confirmed_at && route.status !== "Cancelled").map(async route => (await db.rpc("route_live_channel", { p_route: route.id })).data));
  return <>
    <StatusRefresh channels={channels.filter((channel): channel is string => typeof channel === "string")} />
    <Heading title="Pick up & Return" subtitle="Shop operations · verify physical items, plan routes, and resolve exceptions">
      <Link className="button secondary" href="/pick-return">Open driver view ↗</Link>
    </Heading>
    <nav className="actions" aria-label="Shop logistics sections">
      {[["receiving", "Receiving / Verification", receiving.length], ["returns", "Returned items", returnRoutes.length], ["routes", "Routes", routes.filter(r => !r.confirmed_at && r.status !== "Cancelled").length], ["pending", "Pending · 15 days", pending.length], ["rescheduled", "Re Scheduled", pickupQueue.length + deliveryQueue.length]].map(([key, label, count]) => <Link key={key} className={`button ${view === key ? "" : "secondary"}`} aria-current={view === key ? "page" : undefined} href={`/app/pick-return?view=${key}`}>{label} ({count})</Link>)}
    </nav>
    {!canAny(access,["pr.receiving","pr.returns","pr.reschedule"]) && <p className="notice">Shop verification and scheduling require the corresponding permission.</p>}
    {view === "receiving" && <Panel title="Receiving / Verification">
      <p>Match every piece against the receiving evidence. Production remains locked until every piece is verified.</p>
      {!receiving.length && <p>No pickups awaiting shop verification.</p>}
      {receiving.map(order => <article className="panel" key={order.id}><h3>{jobTitle(order.job_id)}</h3>
        <EvidenceGallery files={documents.filter(file => file.job_id === order.job_id && file.type === "Receiving Evidence" && file.status === "Available")} />
        {can(access,"pr.receiving") && <ShopItemVerification items={pieces(order.job_id)} />}
      </article>)}
    </Panel>}
    {view === "returns" && <Panel title="Undelivered items returned to the shop">
      <p>Failed deliveries keep their route open until the shop verifies every returned piece. Verification does not mark a failed delivery as delivered.</p>
      {!returnRoutes.length && <p>No routes awaiting returned-item verification.</p>}
      {returnRoutes.map(route => <article className="panel" key={route.id}><h3>{route.route_date} · Return</h3>
        {stops.filter(stop => stop.route_id === route.id && stop.status === "Failed").map(stop => <div key={stop.id}><h4>{jobTitle(stop.job_id)}</h4><EvidenceGallery files={documents.filter(file => file.job_id === stop.job_id && file.status === "Available" && ["Delivery Evidence", "Completed Evidence"].includes(file.type))} /></div>)}
        {can(access,"pr.returns") && <><RouteItemVerification route={route.id} kind="Returned" /><Form operation="route-confirm" hidden={{ route_id: route.id }} fields={[]} back="/app/pick-return?view=returns" button="Confirm returned items and close route" /></>}
      </article>)}
    </Panel>}
    {view === "routes" && <Panel title="Routes · plan and execute">
      <form><input type="hidden" name="view" value="routes" /><label>Route date (Denver)<input type="date" name="date" defaultValue={date} required /></label><button>View routes</button></form>
      {["Pickup", "Return"].map(leg => <article className="panel" key={leg}><h3>{leg} · {date}</h3>
        {routes.filter(route => route.route_date === date && route.leg === leg).map(route => {
          const routeStops = stops.filter(stop => stop.route_id === route.id && stop.status !== "Cancelled").sort((a,b) => a.sequence - b.sequence);
          return <section key={route.id}><p>{route.status} · {routeStops.filter(stop => stop.status === "Completed").length}/{routeStops.length} completed · {route.confirmed_at ? "Shop confirmed" : "Route open"}</p><ol>{routeStops.map(stop => <li key={stop.id}>{jobTitle(stop.job_id)} · {stop.status} · ETA {denverDateTime(stop.eta)}</li>)}</ol>
            {can(access,"pr.routes.plan") && !route.confirmed_at && !["Completed","Cancelled"].includes(route.status) && <RouteOperator route={route.id} current={route.operator_id} operators={operators}/>}{can(access,"pr.returns") && leg === "Return" && !route.departed_at && !route.confirmed_at && <RouteItemVerification route={route.id} kind="Loaded" />}
            {can(access,"pr.receiving") && leg === "Pickup" && !route.confirmed_at && <Form operation="route-confirm" hidden={{route_id:route.id}} fields={[]} back={`/app/pick-return?view=routes&date=${date}`} button="Confirm arrival at shop" />}
          </section>;
        })}
        <Link className="button" href={`/pick-return/${leg.toLowerCase()}?date=${date}`}>Execute {leg} route ↗</Link>
      </article>)}
      <Link className="button secondary" href="/app/pick-return?view=rescheduled">Plan / reschedule stops</Link>
    </Panel>}
    {view === "pending" && <Panel title="Pending · 15-day resolution">
      <p>Second attempts remain provisional until the $10 fee is paid. The existing worker releases unpaid reservations at the route cutoff or the 15-day deadline. Shop pickup is free; previous attempt fees remain nonrefundable.</p>
      {!pending.length && <p>No pending reservations or shop collections.</p>}
      {pending.map(order => <article className="panel" key={order.id}><h3>{jobTitle(order.job_id)}</h3><p>{order.delivery_payment_status === "Shop Pickup" ? "Collect at shop · no further delivery" : "Provisional Return · awaiting resolution"}</p><p>{pieces(order.job_id).length} pieces · {order.delivery_payment_status}</p>{order.return_reservation_expires_at && <p>Resolution deadline: {denverDateTime(order.return_reservation_expires_at)}</p>}<p>Open the Job to verify payment or complete the shop handover.</p>{can(access,"pr.returns") && order.delivery_payment_status === "Shop Pickup" && <Form operation="shop-handover" hidden={{id:order.job_id}} fields={[]} back="/app/pick-return?view=pending" button="Confirm paid handover at shop" />}</article>)}
    </Panel>}
    {view === "rescheduled" && <Panel title="Re Scheduled">
      <p>Calendars use configured route days, available slots, payment gates and cutoffs. A missed pickup remains the customer&apos;s choice: reschedule or cancel, without refund.</p>
      {[["Pickup", pickupQueue], ["Return", deliveryQueue]] .map(([leg, queue]) => <section className="panel" key={String(leg)}><h3>{leg === "Return" ? "Delivery" : "Pickup"} to schedule</h3>{!(queue as typeof orders).length && <p>No stops awaiting scheduling.</p>}{(queue as typeof orders).map(order => <details key={order.id}><summary>{jobTitle(order.job_id)} · {leg === "Pickup" ? order.pickup_status : order.return_status}</summary>{leg === "Pickup" && order.pickup_status === "Failed" ? <p>Awaiting customer reschedule or cancellation choice. Open the Job for details.</p> : can(access,"pr.reschedule") && <RouteCalendar job={order.job_id} leg={leg as "Pickup" | "Return"} />}</details>)}</section>)}
    </Panel>}
  </>;
}
