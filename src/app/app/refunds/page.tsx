import { rows } from "@/lib/domain/context";
import { Heading, Panel, Empty, Badge } from "@/components/ui";
import { Form } from "@/components/form";
import { money } from "@/lib/domain/money";

export const dynamic = "force-dynamic";

export default async function RefundsPage() {
  const [requests, jobs] = await Promise.all([
    rows("cancellation_requests", { order: "requested_at", limit: 500 }),
    rows("jobs", { order: "created_at", limit: 500 }),
  ]);

  const jobMap = new Map(jobs.map((job) => [job.id, job]));
  const pending = requests.filter(
    (request) => request.refund_status === "Pending" && Number(request.refund_eligible_amount) > 0,
  );
  const completed = requests.filter((request) => request.refund_status === "Completed");

  return (
    <>
      <Heading
        title="Refunds"
        subtitle="Cancellation refunds are recorded only after ToolTag actually issues the money."
      />

      <section>
        <h2>Pending Refunds</h2>
        {pending.length ? (
          <div className="stack">
            {pending.map((request) => {
              const job = jobMap.get(request.job_id);
              return (
                <Panel key={request.id}>
                  <div className="pick-return-row">
                    <div>
                      <h3>{job?.code ?? request.job_id}</h3>
                      <p className="muted">
                        Cancellation stage: {request.stage_at_request || "—"}
                      </p>
                    </div>
                    <Badge>Refund Pending</Badge>
                  </div>

                  <div className="grid two">
                    <div>
                      <small>Refund to issue</small>
                      <p><strong>{money(request.refund_eligible_amount)}</strong></p>
                    </div>
                    <div>
                      <small>Outstanding amount due</small>
                      <p><strong>{money(request.amount_due)}</strong></p>
                    </div>
                  </div>

                  <p className="muted">
                    Engraving progress at cancellation: {request.items_finished}/
                    {request.items_total} items finished · {request.items_started}/
                    {request.items_total} started or finished.
                  </p>

                  <Form
                    operation="cancellation-refund"
                    hidden={{ request_id: request.id }}
                    back="/app/refunds"
                    fields={[
                      {
                        name: "method",
                        label: "Refund method",
                        required: true,
                        options: [
                          { value: "Zelle", label: "Zelle" },
                          { value: "Venmo", label: "Venmo" },
                          { value: "Cash", label: "Cash" },
                          { value: "Bank Transfer", label: "Bank Transfer" },
                          { value: "Card", label: "Card" },
                          { value: "Other", label: "Other" },
                        ],
                      },
                      {
                        name: "reference",
                        label: "Refund reference",
                        help: "Optional transaction/reference number.",
                      },
                    ]}
                    button="Confirm Refund Issued"
                  />
                </Panel>
              );
            })}
          </div>
        ) : (
          <Empty>No cancellation refunds are waiting to be issued.</Empty>
        )}
      </section>

      <section>
        <h2>Completed Refunds</h2>
        {completed.length ? (
          <div className="stack">
            {completed.map((request) => {
              const job = jobMap.get(request.job_id);
              return (
                <Panel key={request.id}>
                  <div className="pick-return-row">
                    <div>
                      <strong>{job?.code ?? request.job_id}</strong>
                      <p className="muted">
                        Refunded {money(request.refund_eligible_amount)}
                      </p>
                    </div>
                    <Badge>Completed</Badge>
                  </div>
                </Panel>
              );
            })}
          </div>
        ) : (
          <Empty>No completed cancellation refunds yet.</Empty>
        )}
      </section>
    </>
  );
}
