import { can, canAny } from "@/lib/auth/permissions";
import { RouteOperator } from "@/components/route-operator";
import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Heading, Panel } from "@/components/ui";
import { ShopItemVerification } from "@/components/shop-item-verification";
import { ShopDeliveryBoard, type DeliveryBlock } from "@/components/shop-delivery-board";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { RouteCalendar } from "@/components/route-calendar";
import { StatusRefresh } from "@/components/status-refresh";
import { Form } from "@/components/form";
import { denverDateTime, TOOLTAG_TIMEZONE } from "@/lib/domain/time";

export const dynamic = "force-dynamic";

export default async function ShopPickReturn({ searchParams }: {
  searchParams: Promise<{ view?: string; date?: string; leg?: string }>;
}) {
  const { db, unit, access } = await requirePermission("pr.routes.plan","pr.routes.live","pr.receiving","pr.returns","pr.reschedule");
  const operators = can(access,"pr.routes.plan") ? (await db.rpc("route_operators")).data ?? [] : [];
  const query = await searchParams;
  const deliveryAccess = canAny(access,["pr.routes.plan","pr.routes.live","pr.returns","pr.reschedule"]);
  const delivery = query.leg === "Delivery" && deliveryAccess;
  const views = ["receiving", "routes", "rescheduled"];
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
  const [orders, jobs, items, routes, stops, documents, flows, customers, logistics] = await Promise.all([
    load("pick_return_orders"), load("jobs"), load("job_items"), load("pick_return_routes"),
    load("pick_return_stops"), load("documents"), load("commercial_flows"), load("customers"), load("quote_logistics"),
  ]);
  const openOrders = orders.filter(order => jobs.some(job => job.id === order.job_id && !["Cancelled", "Closed"].includes(job.status)));
  const pieces = (job: string) => items.filter(item => item.job_id === job && item.stage !== "Cancelled");
  const receiving = openOrders.filter(order => order.pickup_status === "Picked Up" && pieces(order.job_id).some(item => !item.shop_received_at));
  const pickupQueue = openOrders.filter(order => ["Failed", "Not Scheduled"].includes(order.pickup_status));
  const jobTitle = (id: string) => {
    const job = jobs.find(row => row.id === id);
    const flow = flows.find(row => row.id === job?.flow_id);
    const customer = customers.find(row => row.id === flow?.customer_id);
    return <Link href={`/app/jobs/${id}`}>{job?.code ?? "Job"} · {customer?.name ?? "Customer"}</Link>;
  };
  const {data: queueState, error: queueError} = delivery ? await db.rpc("delivery_queue_state") : {data: [], error: null};
  if (queueError) throw new Error("Could not load delivery queues");
  const {data: deliveryDrivers, error: driverError} = delivery ? await db.rpc("delivery_block_drivers") : {data: [],error:null};
  if (driverError) throw new Error("Could not load delivery drivers");
  const drivers = (deliveryDrivers ?? []) as {id:string;name:string;selectable:boolean}[];
  const states = (queueState ?? []) as {job:string;eligible:boolean;retry_paid:boolean;awaiting_resolution:boolean}[];
  const deliveryOrders = openOrders.filter(o => ["Pickup & Delivery","Drop-off + Delivery"].includes(o.service_method));
  const jobInfo = (id:string) => {
    const job = jobs.find(j => j.id === id);
    const order = orders.find(o => o.job_id === id);
    const flow = flows.find(f => f.id === job?.flow_id);
    const customer = customers.find(c => c.id === flow?.customer_id);
    return {id, code:job?.code ?? "Job", status:order?.delivery_payment_status === "Pending Delivery" ? "Pending Delivery" : order?.return_status ?? job?.status ?? "", finished:order?.production_ready_at ?? job?.created_at, name:customer?.name ?? "Customer", address:logistics.find(l => l.quote_id === job?.quote_id)?.delivery_address ?? "", deadline:order?.return_reservation_expires_at};
  };
  const byFinished = (a:ReturnType<typeof jobInfo>,b:ReturnType<typeof jobInfo>) => a.finished.localeCompare(b.finished) || a.code.localeCompare(b.code);
  const deliveryQueue = deliveryOrders.filter(o => states.find(s => s.job === o.job_id)?.eligible).map(o => jobInfo(o.job_id)).sort(byFinished);
  const failedDeliveries = deliveryOrders.filter(o => states.find(s => s.job === o.job_id)?.awaiting_resolution).map(o => jobInfo(o.job_id)).sort(byFinished);
  const deliveryBlocks:DeliveryBlock[] = routes.filter(r => r.leg === "Return" && r.status !== "Cancelled").map(r => ({
    id:r.id,number:r.block_number ?? 1,date:r.route_date,capacity:r.delivery_capacity ?? 20,reason:r.capacity_authorization_reason ?? "",operator:r.operator_id,driver:drivers.find(o => o.id === r.operator_id)?.name ?? "",closed:Boolean(r.confirmed_at),editable:!r.departed_at && !r.started_at && !r.confirmed_at && !["Completed","Cancelled"].includes(r.status),
    stops:stops.filter(s => s.route_id === r.id && s.status !== "Cancelled").sort((a,b) => a.sequence-b.sequence).map(s => ({...jobInfo(s.job_id),stop:s.id,state:s.status,sequence:s.sequence,address:s.address || jobInfo(s.job_id).address,delivered:s.status === "Completed" ? s.completed_at : null,returnedEvidence:documents.filter(d => d.job_id === s.job_id && ["Delivery Evidence","Completed Evidence","Receiving Evidence"].includes(d.type) && d.status === "Available").map(d => ({id:d.id,name:d.file_name || d.original_file_name || d.name || "Evidence"})),evidence:documents.filter(d => d.job_id === s.job_id && d.type === "Delivery Evidence" && d.status === "Available").map(d => ({id:d.id,name:d.file_name || d.original_file_name || d.name || "Delivery evidence"}))}))
  }));
  const channels = await Promise.all(routes.filter(route => !route.confirmed_at && route.status !== "Cancelled").map(async route => (await db.rpc("route_live_channel", { p_route: route.id })).data));
  return <>
    <StatusRefresh channels={channels.filter((channel): channel is string => typeof channel === "string")} />
    <Heading title="Pick Up & Delivery" subtitle="Shop operations · verify physical items, plan routes, and resolve exceptions">
      <Link className="button secondary" href="/pick-return">Open driver view ↗</Link>
    </Heading>
    <nav className="actions" aria-label="Logistics leg"><Link className={`button ${delivery ? "secondary" : ""}`} href="/app/pick-return?leg=Pickup">Pick Up</Link>{deliveryAccess && <Link className={`button ${delivery ? "" : "secondary"}`} href="/app/pick-return?leg=Delivery">Delivery</Link>}</nav>
    {delivery ? <ShopDeliveryBoard queue={deliveryQueue} returns={failedDeliveries} blocks={deliveryBlocks} operators={drivers.filter(d => d.selectable)} today={date} /> : <>
    <nav className="actions" aria-label="Pickup sections">{[["receiving","Receiving / Verification",receiving.length],["routes","Routes",routes.filter(r => r.leg === "Pickup" && !r.confirmed_at && r.status !== "Cancelled").length],["rescheduled","To Schedule",pickupQueue.length]].map(([key,label,count]) => <Link key={key} className={`button ${view === key ? "" : "secondary"}`} href={`/app/pick-return?leg=Pickup&view=${key}`}>{label} ({count})</Link>)}</nav>
    {!canAny(access,["pr.receiving","pr.returns","pr.reschedule"]) && <p className="notice">Shop verification and scheduling require the corresponding permission.</p>}
    {view === "receiving" && <Panel title="Receiving / Verification">
      <p>Match every piece against the receiving evidence. Production remains locked until every piece is verified.</p>
      {!receiving.length && <p>No pickups awaiting shop verification.</p>}
      {receiving.map(order => <article className="panel" key={order.id}><h3>{jobTitle(order.job_id)}</h3>
        <EvidenceGallery files={documents.filter(file => file.job_id === order.job_id && file.type === "Receiving Evidence" && file.status === "Available")} />
        {can(access,"pr.receiving") && <ShopItemVerification items={pieces(order.job_id)} />}
      </article>)}
    </Panel>}
    {view === "routes" && <Panel title="Routes · plan and execute">
      <form><input type="hidden" name="view" value="routes" /><label>Route date (Denver)<input type="date" name="date" defaultValue={date} required /></label><button>View routes</button></form>
      {["Pickup"].map(leg => <article className="panel" key={leg}><h3>Pick Up · {date}</h3>
        {routes.filter(route => route.route_date === date && route.leg === leg).map(route => {
          const routeStops = stops.filter(stop => stop.route_id === route.id && stop.status !== "Cancelled").sort((a,b) => a.sequence - b.sequence);
          return <section key={route.id}><p>{route.status} · {routeStops.filter(stop => stop.status === "Completed").length}/{routeStops.length} completed · {route.confirmed_at ? "Shop confirmed" : "Route open"}</p><ol>{routeStops.map(stop => <li key={stop.id}>{jobTitle(stop.job_id)} · {stop.status} · ETA {denverDateTime(stop.eta)}</li>)}</ol>
            {can(access,"pr.routes.plan") && !route.confirmed_at && !["Completed","Cancelled"].includes(route.status) && <RouteOperator route={route.id} current={route.operator_id} operators={operators}/>}
            {can(access,"pr.receiving") && leg === "Pickup" && !route.confirmed_at && <Form operation="route-confirm" hidden={{route_id:route.id}} fields={[]} back={`/app/pick-return?view=routes&date=${date}`} button="Confirm arrival at shop" />}
          </section>;
        })}
        <Link className="button" href={`/pick-return/${leg.toLowerCase()}?date=${date}`}>Execute Pick Up route ↗</Link>
      </article>)}
      <Link className="button secondary" href="/app/pick-return?view=rescheduled">Plan / reschedule stops</Link>
    </Panel>}
    {view === "rescheduled" && <Panel title="Re Scheduled">
      <p>Calendars use configured route days, available slots, payment gates and cutoffs. A missed pickup remains the customer&apos;s choice: reschedule or cancel, without refund.</p>
      {[["Pickup", pickupQueue]] .map(([leg, queue]) => <section className="panel" key={String(leg)}><h3>{leg === "Return" ? "Delivery" : "Pick Up"} to schedule</h3>{!(queue as typeof orders).length && <p>No stops awaiting scheduling.</p>}{(queue as typeof orders).map(order => <details key={order.id}><summary>{jobTitle(order.job_id)} · {leg === "Pickup" ? order.pickup_status : order.return_status}</summary>{leg === "Pickup" && order.pickup_status === "Failed" ? <p>Awaiting customer reschedule or cancellation choice. Open the Job for details.</p> : can(access,"pr.reschedule") && <RouteCalendar job={order.job_id} leg={leg as "Pickup" | "Return"} />}</details>)}</section>)}
    </Panel>}
    </>}
  </>;
}
