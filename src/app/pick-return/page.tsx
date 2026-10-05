import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { Badge, Empty, Heading, Panel, Table } from "@/components/ui";
import { money } from "@/lib/domain/money";

export const dynamic = "force-dynamic";

export default async function PickReturnPage() {
  const [orders, routes, stops, jobs] = await Promise.all([
    rows("pick_return_orders"),
    rows("pick_return_routes", { order: "route_date" }),
    rows("pick_return_stops"),
    rows("jobs"),
  ]);

  const jobById = new Map(jobs.map((job) => [job.id, job]));
  const activeRoutes = routes
    .filter((route) => ["Draft", "Active"].includes(route.status))
    .sort((a, b) =>
      String(a.route_date).localeCompare(String(b.route_date)) ||
      String(a.leg).localeCompare(String(b.leg)),
    );

  const readyForPickup = orders.filter(
    (order) =>
      order.fee_status === "Confirmed" &&
      order.pickup_status === "Not Scheduled",
  );

  const readyForReturn = orders.filter(
    (order) =>
      order.return_status === "Delivery In Progress" &&
      !order.hold_until_paid,
  );

  return (
    <>
      <Heading
        title="Pick & Return"
        subtitle="Dedicated route mode. Workspace actions stay outside this screen."
      />

      <Panel title="Ready">
        <p>
          <strong>{readyForPickup.length}</strong> ready for Pickup scheduling ·{" "}
          <strong>{readyForReturn.length}</strong> ready for Return scheduling
        </p>
        <p className="muted">
          Automatic customer calendar scheduling is intentionally disabled for now.
          The database and route workflow are ready for scheduling rules when capacity
          and timing parameters are finalized.
        </p>
      </Panel>

      {activeRoutes.length ? (
        activeRoutes.map((route) => {
          const routeStops = stops
            .filter((stop) => stop.route_id === route.id && stop.status !== "Cancelled")
            .sort((a, b) => Number(a.sequence) - Number(b.sequence));

          return (
            <Panel
              key={route.id}
              title={`${route.leg} · ${new Date(`${route.route_date}T12:00:00`).toLocaleDateString("en-US")}`}
            >
              {routeStops.length ? (
                <Table headers={["Stop", "Job", "Status", "ETA", ""]}>
                  {routeStops.map((stop) => {
                    const job = jobById.get(stop.job_id);
                    return (
                      <tr key={stop.id}>
                        <td>#{stop.sequence}</td>
                        <td>{job?.code ?? "Job"}</td>
                        <td><Badge>{stop.status}</Badge></td>
                        <td>
                          {stop.eta
                            ? new Date(stop.eta).toLocaleTimeString("en-US", {
                                hour: "numeric",
                                minute: "2-digit",
                              })
                            : "—"}
                        </td>
                        <td>
                          <Link href={`/pick-return/stops/${stop.id}`}>
                            Open →
                          </Link>
                        </td>
                      </tr>
                    );
                  })}
                </Table>
              ) : (
                <Empty>No active stops on this route.</Empty>
              )}
            </Panel>
          );
        })
      ) : (
        <Panel>
          <Empty>No active Pickup or Return routes.</Empty>
        </Panel>
      )}

      {(readyForPickup.length > 0 || readyForReturn.length > 0) && (
        <Panel title="Waiting for scheduling">
          {[...readyForPickup, ...readyForReturn].map((order) => {
            const job = jobById.get(order.job_id);
            return (
              <p key={order.job_id}>
                <Link href={`/app/jobs/${order.job_id}`}>
                  {job?.code ?? order.job_id}
                </Link>
                {" · "}
                Pickup fee {money(order.fee_amount)} — {order.fee_status}
                {" · "}
                Pickup {order.pickup_status}
                {" · "}
                Return {order.return_status}
              </p>
            );
          })}
        </Panel>
      )}
    </>
  );
}
