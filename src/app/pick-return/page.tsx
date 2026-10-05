import Link from "next/link";
import { context } from "@/lib/domain/context";
import { Form } from "@/components/form";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { EvidenceUpload } from "@/components/evidence-upload";
import { Badge, Panel, Empty } from "@/components/ui";
import { money } from "@/lib/domain/money";

export const dynamic = "force-dynamic";

function dateTime(value?: string | null) {
  return value ? new Date(value).toLocaleString("en-US") : "—";
}

export default async function PickReturnPage() {
  const { db, unit, role } = await context();

  const [{ data: orders }, { data: jobs }, { data: routes }, { data: stops }, { data: docs }] =
    await Promise.all([
      db.from("pick_return_orders").select("*").eq("unit_id", unit),
      db.from("jobs").select("*").eq("unit_id", unit),
      db.from("pick_return_routes").select("*").eq("unit_id", unit),
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
    .filter((stop) => stop.status !== "Cancelled")
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

      <section className="panel">
        <h2>Service Queue</h2>
        {(orders ?? []).length ? (
          <div className="stack">
            {(orders ?? []).map((order) => {
              const job = jobMap.get(order.job_id);
              if (!job) return null;
              return (
                <div className="item" key={order.job_id}>
                  <div className="pick-return-row">
                    <div>
                      <strong>{job.code}</strong>
                      <p className="muted">
                        {job.work_stage} · Pickup fee {money(order.fee_amount)} · {order.fee_status}
                      </p>
                    </div>
                    <div className="actions">
                      <Badge>Pickup: {order.pickup_status}</Badge>
                      <Badge>Return: {order.return_status}</Badge>
                    </div>
                  </div>

                  {order.fee_status !== "Confirmed" && order.pickup_status !== "Picked Up" && (
                    <p className="notice">
                      Pickup is locked until the {money(order.fee_amount)} Pickup fee is confirmed.
                    </p>
                  )}

                  {order.fee_status === "Confirmed" &&
                    !["Picked Up", "Cancelled"].includes(order.pickup_status) && (
                      <details>
                        <summary>Schedule / reschedule Pickup</summary>
                        <p className="muted">
                          Temporary manual scheduler. Enter ISO timestamps including the local UTC offset until the automatic calendar is enabled.
                        </p>
                        <Form
                          operation="pick-return-schedule"
                          hidden={{ job_id: order.job_id, leg: "Pickup" }}
                          back="/pick-return"
                          fields={[
                            {
                              name: "window_start",
                              label: "Pickup window start",
                              required: true,
                              help: "Example: 2026-10-10T08:00:00-06:00",
                            },
                            {
                              name: "window_end",
                              label: "Pickup window end",
                              required: true,
                              help: "Example: 2026-10-10T12:00:00-06:00",
                            },
                            {
                              name: "eta",
                              label: "Initial ETA",
                              help: "Optional ISO timestamp with offset",
                            },
                          ]}
                          button="Schedule Pickup"
                        />
                      </details>
                    )}

                  {["Delivery In Progress", "Scheduled"].includes(order.return_status) && (
                    <details open={order.return_status === "Delivery In Progress"}>
                      <summary>Schedule / reschedule Return</summary>
                      <Form
                        operation="pick-return-schedule"
                        hidden={{ job_id: order.job_id, leg: "Return" }}
                        back="/pick-return"
                        fields={[
                          {
                            name: "window_start",
                            label: "Return window start",
                            required: true,
                            help: "Example: 2026-10-11T16:00:00-06:00",
                          },
                          {
                            name: "window_end",
                            label: "Return window end",
                            required: true,
                            help: "Example: 2026-10-11T18:00:00-06:00",
                          },
                          {
                            name: "eta",
                            label: "Initial ETA",
                            help: "Optional ISO timestamp with offset",
                          },
                        ]}
                        button="Schedule Return"
                      />
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
                  </div>
                  <Badge>{route.route_date}</Badge>
                </div>

                {stop.status === "Scheduled" && (
                  <Form
                    operation="pick-return-stop"
                    hidden={{ stop_id: stop.id, action: "en-route" }}
                    fields={[]}
                    back="/pick-return"
                    button="Start · En Route"
                  />
                )}

                {stop.status === "En Route" && (
                  <Form
                    operation="pick-return-stop"
                    hidden={{ stop_id: stop.id, action: "arrived" }}
                    fields={[]}
                    back="/pick-return"
                    button="Arrived"
                  />
                )}

                {stop.status === "Arrived" && (
                  <>
                    <div className="item">
                      <h3>{evidenceLabel}</h3>
                      <EvidenceGallery files={evidence} />
                      {role === "admin" && (
                        <details open={!evidence.length}>
                          <summary>{isPickup ? "Add Pickup Receiving Evidence" : "Add Return Delivery Evidence"}</summary>
                          <EvidenceUpload
                            config={{
                              jobId: job.id,
                              pickReturnStopId: stop.id,
                              type: isPickup ? "Receiving Evidence" : "Delivery Evidence",
                              defaultVisibility: isPickup ? "internal" : "customer",
                              photoOnly: true,
                            }}
                            button="Upload Photo"
                            accept="image/*"
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
                        back="/pick-return"
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
