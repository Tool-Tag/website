import {RouteCalendar} from "@/components/route-calendar";
import {denverDateTime} from "@/lib/domain/time";
import Link from "next/link";
import { context } from "@/lib/domain/context";
import { Form } from "@/components/form";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { EvidenceCapture } from "@/components/evidence-capture";
import { Badge, Panel, Empty } from "@/components/ui";
import { money } from "@/lib/domain/money";

export const dynamic = "force-dynamic";

function dateTime(value?: string | null) {
  return value ? denverDateTime(value) : "—";
}

export async function DriverRoute({leg,date,routeId}:{leg:"pickup"|"return";date:string;routeId?:string}) {
  const query = {mode:leg,route:routeId};
  const mode = query.mode === "pickup" ? "Pickup" : query.mode === "return" ? "Return" : null;
  const { db, unit, role } = await context();

  const [{ data: orders }, { data: jobs }, { data: routes }, { data: stops }, { data: docs }] =
    await Promise.all([
      db.from("pick_return_orders").select("*").eq("unit_id", unit),
      db.from("jobs").select("*").eq("unit_id", unit),
      db.from("pick_return_routes").select("*").eq("unit_id", unit).eq("route_date", date),
      db.from("pick_return_stops").select("*").eq("unit_id", unit),
      db
        .from("documents")
        .select("*")
        .eq("unit_id", unit)
        .in("type", ["Receiving Evidence", "Delivery Evidence"]),
    ]);

  const jobMap = new Map((jobs ?? []).map((job) => [job.id, job]));
  const routeMap = new Map((routes ?? []).map((route) => [route.id, route]));
  const activeStops = [...(stops ?? [])]
    .filter((stop) => stop.status !== "Cancelled" && routeMap.get(stop.route_id)?.leg === mode && (!query.route || stop.route_id === query.route))
    .sort((a, b) => {
      const ar = routeMap.get(a.route_id);
      const br = routeMap.get(b.route_id);
      const ad = String(ar?.route_date ?? "");
      const bd = String(br?.route_date ?? "");
      return ad.localeCompare(bd) || String(ar?.leg ?? "").localeCompare(String(br?.leg ?? "")) || Number(a.sequence) - Number(b.sequence);
    });

  const evidenceFor = (stopId: string, type: string) =>
    (docs ?? []).filter(
      (doc) => doc.pick_return_stop_id === stopId && doc.type === type,
    );

  return (
    <main className="public pick-return-mode">
      <div className="pick-return-head">
        <div>
          <p className="eyebrow">ToolTag · Operations Mode</p>
          <h1>Pick & Return</h1>
          <p className="muted">
            Dedicated Pickup and Return workflow. Jobs, customers, evidence, and payments remain connected to the Workspace.
          </p>
        </div>
        <Link className="button secondary" href="/app">
          Back to Workspace
        </Link>
      </div>

      {mode && <section className="panel"><h2>{mode} routes</h2><div className="stack">{(routes ?? []).filter(r=>r.leg===mode).sort((a,b)=>a.route_date.localeCompare(b.route_date)).map(r=><div className="item" key={r.id}><Link href={`/pick-return?mode=${mode.toLowerCase()}&route=${r.id}`}>{r.route_date} · {r.status}</Link>{!r.confirmed_at && (stops ?? []).some(s=>s.route_id===r.id && ["Completed","Failed"].includes(s.status)) && !(stops ?? []).some(s=>s.route_id===r.id && !["Completed","Failed","Cancelled"].includes(s.status)) && <Form operation="route-confirm" hidden={{route_id:r.id}} fields={[]} back={`/pick-return?mode=${mode.toLowerCase()}`} button={mode === "Pickup" ? "Confirm arrival at shop" : "Confirm all delivered"} />}</div>)}</div></section>}
      <section className="panel">
        <h2>Service Queue</h2>
        {(orders ?? []).length ? (
          <div className="stack">
            {(orders ?? []).filter(order => mode === "Pickup" ? order.pickup_status !== "Not Applicable" : mode === "Return" ? order.return_status !== "Not Applicable" : false).map((order) => {
              const job = jobMap.get(order.job_id);
              if (!job) return null;
              return (
                <div className="item" key={order.job_id}>
                  <div className="pick-return-row">
                    <div>
                      <strong>{job.code}</strong>
                      <p className="muted">
                        {job.work_stage} · Logistics fee {money(order.fee_amount)} · {order.fee_status}
                      </p>
                    </div>
                    <div className="actions">
                      <Badge>Pickup: {order.pickup_status}</Badge>
                      <Badge>Return: {order.return_status}</Badge>
                    </div>
                  </div>

                  {order.fee_status !== "Confirmed" && (
                    <p className="notice">
                      ToolTag logistics actions are locked until the{" "}
                      {money(order.fee_amount)} logistics fee is confirmed.
                    </p>
                  )}

                  {order.fee_status === "Confirmed" &&
                    !["Not Applicable", "Picked Up", "Cancelled"].includes(order.pickup_status) && (
                      <details>
                        <summary>Schedule / reschedule Pickup</summary>
                        <RouteCalendar job={order.job_id} leg="Pickup" />
                      </details>
                    )}

                  {["Delivery In Progress", "Scheduled"].includes(order.return_status) && (
                    <details open={order.return_status === "Delivery In Progress"}>
                      <summary>Schedule / reschedule Return</summary>
                      <RouteCalendar job={order.job_id} leg="Return" />
                    </details>
                  )}
                </div>
              );
            })}
          </div>
        ) : (
          <Empty>No Pickup & Return Jobs are currently active.</Empty>
        )}
      </section>

      <section>
        <h2>Route Stops</h2>
        {activeStops.length ? (
          activeStops.map((stop) => {
            const route = routeMap.get(stop.route_id);
            const job = jobMap.get(stop.job_id);
            const order = (orders ?? []).find(order => order.job_id === stop.job_id);
            if (!route || !job) return null;
            const isPickup = route.leg === "Pickup";
            const evidenceType = isPickup ? "Receiving Evidence" : "Delivery Evidence";
            const evidence = evidenceFor(stop.id, evidenceType);
            const evidenceLabel = isPickup ? "Pickup receiving photos" : "Return delivery photos";

            return (
              <Panel
                key={stop.id}
                title={`${route.leg} · Stop ${stop.sequence} · ${job.code}`}
              >
                <div className="pick-return-row">
                  <div>
                    <p>
                      <strong>{stop.status}</strong>
                    </p>
                    <p className="muted">
                      Window: {dateTime(stop.window_start)} → {dateTime(stop.window_end)}
                    </p>
                    <p className="muted">ETA: {dateTime(stop.eta)}</p>
                    {stop.address && <p><strong>Address:</strong> {stop.address}</p>}
                    {(stop.customer_phone || stop.customer_email) && (
                      <p className="muted">
                        {stop.customer_phone || "No phone"} · {stop.customer_email || "No email"}
                      </p>
                    )}
                  </div>
                  <Badge>{route.route_date}</Badge>
                </div>

                {stop.status === "Requested" && (
                  <p className="notice">
                    Requested by the customer. This stop remains unconfirmed until
                    the logistics payment is confirmed.
                  </p>
                )}

                {stop.status === "Scheduled" && (
                  <Form
                    operation="pick-return-stop"
                    hidden={{ stop_id: stop.id, action: "en-route" }}
                    fields={[]}
                    back={`/pick-return?mode=${mode?.toLowerCase() || "pickup"}${query.route ? `&route=${query.route}` : ""}`}
                    button="Start · En Route"
                  />
                )}

                {stop.status === "En Route" && (
                  <Form
                    operation="pick-return-stop"
                    hidden={{ stop_id: stop.id, action: "arrived" }}
                    fields={[]}
                    back={`/pick-return?mode=${mode?.toLowerCase() || "pickup"}${query.route ? `&route=${query.route}` : ""}`}
                    button="Arrived"
                  />
                )}

                {stop.status === "Arrived" && (
                  <>
                    {!isPickup && <>{order?.delivery_payment_method === "Cash" && <Form operation="route-cash" hidden={{stop_id:stop.id}} fields={[]} back={`/pick-return?mode=return&route=${route.id}`} button="Confirm cash collected" />}<label><input type="checkbox" /> Start recording before exiting the vehicle</label><p className="notice">Never leave items at the door. Confirm payment before handing over items.</p><Form operation="pick-return-stop" hidden={{stop_id:stop.id, action:"not-home"}} fields={[]} back={`/pick-return?mode=return&route=${route.id}`} button="Customer not home" /></>}
                    <div className="item">
                      <h3>{evidenceLabel}</h3>
                      <EvidenceGallery files={evidence} />
                      {role === "admin" && (
                        <details open={!evidence.length}>
                          <summary>{isPickup ? "Add Pickup Receiving Evidence" : "Add Return Delivery Evidence"}</summary>
                          <EvidenceCapture
                            config={{
                              jobId: job.id,
                              pickReturnStopId: stop.id,
                              type: isPickup ? "Receiving Evidence" : "Delivery Evidence",
                              defaultVisibility: isPickup ? "internal" : "customer",
                            }}
                          />
                        </details>
                      )}
                    </div>

                    {evidence.length > 0 && (
                      <Form
                        operation="pick-return-stop"
                        hidden={{
                          stop_id: stop.id,
                          action: isPickup ? "picked-up" : "delivered",
                        }}
                        fields={[]}
                        back={`/pick-return?mode=${mode?.toLowerCase() || "pickup"}${query.route ? `&route=${query.route}` : ""}`}
                        button={isPickup ? "Picked Up" : "Delivered"}
                      />
                    )}
                  </>
                )}

                {stop.status === "Completed" && (
                  <p className="notice success">
                    {isPickup ? "Items picked up and Receiving Evidence recorded." : "Items delivered and Delivery Evidence recorded."}
                  </p>
                )}
              </Panel>
            );
          })
        ) : (
          <Empty>No route stops are scheduled.</Empty>
        )}
      </section>
    </main>
  );
}
