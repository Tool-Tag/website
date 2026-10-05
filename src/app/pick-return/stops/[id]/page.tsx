import Link from "next/link";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { Form } from "@/components/form";
import { rows, context } from "@/lib/domain/context";
import { Badge, Empty, Heading, Panel } from "@/components/ui";

export const dynamic = "force-dynamic";

export default async function PickReturnStopPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { role } = await context();
  const stop = (await rows("pick_return_stops", { id }))[0];
  if (!stop) return <Empty>Route stop not found.</Empty>;

  const [route, job, docs] = await Promise.all([
    rows("pick_return_routes", { id: stop.route_id }),
    rows("jobs", { id: stop.job_id }),
    rows("documents", { field: "pick_return_stop_id", value: id }),
  ]);

  const leg = route[0]?.leg ?? "Pickup";
  const currentJob = job[0];
  const evidenceType =
    leg === "Pickup" ? "Receiving Evidence" : "Delivery Evidence";
  const evidence = docs.filter((doc) => doc.type === evidenceType);

  return (
    <>
      <Heading
        title={currentJob?.code ?? "Route Stop"}
        subtitle={`${leg} · Stop #${stop.sequence}`}
      >
        <Link className="button secondary" href="/pick-return">
          Route
        </Link>
      </Heading>

      <Panel title={leg}>
        <p>
          Status: <Badge>{stop.status}</Badge>
        </p>
        {stop.eta && (
          <p className="muted">
            ETA: {new Date(stop.eta).toLocaleString("en-US")}
          </p>
        )}

        {role === "admin" && stop.status === "Scheduled" && (
          <Form
            operation="pick-return-stop"
            hidden={{ id, action: "en-route" }}
            fields={[]}
            back={`/pick-return/stops/${id}`}
            button="Start · En Route"
          />
        )}

        {role === "admin" && stop.status === "En Route" && (
          <Form
            operation="pick-return-stop"
            hidden={{ id, action: "arrived" }}
            fields={[]}
            back={`/pick-return/stops/${id}`}
            button="Arrived"
          />
        )}
      </Panel>

      {["En Route", "Arrived"].includes(stop.status) && (
        <Panel title={evidenceType}>
          <EvidenceGallery files={evidence} />
          {role === "admin" && (
            <details open={stop.status === "Arrived" && evidence.length === 0}>
              <summary>Link route evidence from Drive</summary>
              <p className="muted">
                Photos recorded here are attached directly to this {leg} stop.
              </p>
              <Form
                operation="document"
                hidden={{
                  job_id: stop.job_id,
                  pick_return_stop_id: id,
                  type: evidenceType,
                }}
                back={`/pick-return/stops/${id}`}
                fields={[
                  {
                    name: "file_name",
                    label: "Name",
                    required: true,
                    value: `${currentJob?.code ?? "Job"}-${leg}-${String(evidence.length + 1).padStart(2, "0")}.jpg`,
                  },
                  {
                    name: "drive_file_id",
                    label: "Drive File ID",
                    required: true,
                  },
                ]}
              />
            </details>
          )}
        </Panel>
      )}

      {role === "admin" && stop.status === "Arrived" && evidence.length > 0 && (
        <Form
          operation="pick-return-stop"
          hidden={{
            id,
            action: leg === "Pickup" ? "picked-up" : "delivered",
          }}
          fields={[]}
          back="/pick-return"
          button={leg === "Pickup" ? "Picked Up" : "Delivered"}
        />
      )}
    </>
  );
}
