import { EvidenceGallery } from "@/components/evidence-gallery";
import { EvidenceCapture } from "@/components/evidence-capture";
import { EvidenceUpload } from "@/components/evidence-upload";
import { JobLifecycle } from "@/components/job-lifecycle";
import { JobTabs } from "@/components/job-tabs";
import { AcceptedDocuments } from "@/components/accepted-documents";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
import { QuoteScope } from "@/components/quote-scope";
import { Form } from "@/components/form";
import { WorkPreparation } from "@/components/work-preparation";
import { money } from "@/lib/domain/money";
import { jobStatusLabel, paymentStatusLabel, workStageLabel } from "@/lib/domain/status-labels";

export async function Jobs({ id }: { id?: string }) {
  if (!id) {
    const list = await rows("jobs", { order: "created_at" });

    const activeJobs = list.filter(
      (j) =>
        !["Payment", "Payment Verification", "Closed", "Issue Review"].includes(
          j.work_stage ?? "Not Started",
        ) &&
        !["Cancelled"].includes(j.status),
    );
    const reviewJobs = list.filter(
      (j) => j.work_stage === "Issue Review" || j.status === "Issue / Review",
    );
    const paymentJobs = list.filter((j) =>
      ["Payment", "Payment Verification"].includes(j.work_stage),
    );
    const completedJobs = list.filter((j) => j.work_stage === "Closed");
    const cancelledJobs = list.filter((j) => j.status === "Cancelled");

    const jobTable = (jobs: typeof list, empty: string) => (
      <Panel>
        {jobs.length ? (
          <Table headers={["Trabajo", "Etapa", "Estado", "Creado"]}>
            {jobs.map((j) => (
              <tr key={j.id}>
                <td>
                  <Link href={`/app/jobs/${j.id}`}>{j.code}</Link>
                </td>
                <td>
                  <Badge>{workStageLabel(j.work_stage ?? "Not Started")}</Badge>
                </td>
                <td>
                  <Badge>{jobStatusLabel(j.status)}</Badge>
                </td>
                <td>{new Date(j.created_at).toLocaleDateString("es-US")}</td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty>{empty}</Empty>
        )}
      </Panel>
    );

    return (
      <>
        <Heading
          title="Trabajos"
          subtitle="Organizados según su etapa operativa."
        />
        <JobTabs
          defaultTab="active"
          tabs={[
            {
              id: "active",
              label: "Activos",
              count: activeJobs.length,
              content: jobTable(activeJobs, "No hay trabajos activos."),
            },
            {
              id: "review",
              label: "Revisión",
              count: reviewJobs.length,
              content: jobTable(reviewJobs, "No hay trabajos en revisión."),
            },
            {
              id: "payments",
              label: "Pagos",
              count: paymentJobs.length,
              content: jobTable(paymentJobs, "No hay trabajos pendientes de pago."),
            },
            {
              id: "completed",
              label: "Completados",
              count: completedJobs.length,
              content: jobTable(completedJobs, "No hay trabajos completados."),
            },
            ...(cancelledJobs.length
              ? [
                  {
                    id: "cancelled",
                    label: "Cancelados",
                    count: cancelledJobs.length,
                    content: jobTable(cancelledJobs, "No hay trabajos cancelados."),
                  },
                ]
              : []),
          ]}
        />
      </>
    );
  }

  const { role, db } = await context();
  const j = (await rows("jobs", { id }))[0];
  if (!j) return <Empty>Trabajo no encontrado.</Empty>;

  const [docs, sales, paymentRequests, rawJobItems, pickupRows, cancellationRows] = await Promise.all([
    rows("documents", { field: "job_id", value: id }),
    rows("sale_balances", { field: "job_id", value: id }),
    rows("payment_requests", { field: "job_id", value: id, order: "submitted_at" }),
    rows("job_items", { field: "job_id", value: id, limit: 500 }),
    rows("pick_return_orders", { field: "job_id", value: id }),
    rows("cancellation_requests", { field: "job_id", value: id, order: "requested_at" }),
  ]);

  const jobItems = [...rawJobItems].sort((a, b) => Number(a.sequence) - Number(b.sequence));
  const pickupReturn = pickupRows[0] ?? null;
  const activeCancellation =
    cancellationRows.find((request) => request.status === "Requested") ?? null;
  const cancelledRequest =
    cancellationRows.find((request) => request.status === "Cancelled") ?? null;

  const pendingPayment = paymentRequests.find(
    (request) => request.status === "Pending Verification",
  );

  let pendingProofUrl: string | null = null;
  if (role === "admin" && pendingPayment?.proof_path) {
    const { data } = await db.storage
      .from("payment-proofs")
      .createSignedUrl(pendingPayment.proof_path, 3600);
    pendingProofUrl = data?.signedUrl ?? null;
  }

  const scope = await rows("quote_items", {
    field: "quote_id",
    value: j.quote_id,
  });

  const receivingFiles = docs.filter((d) => d.type === "Receiving Evidence");
  const stage = j.work_stage ?? "Not Started";
  const currentItem = jobItems.find((item) => !["Finished", "Cancelled"].includes(item.stage));
  const finishedItems = jobItems.filter((item) => item.stage === "Finished").length;
  const itemEvidence = currentItem
    ? docs.filter(
        (d) =>
          ["Production Evidence", "Finished Evidence", "Completed Evidence"].includes(d.type) &&
          d.job_item_id === currentItem.id,
      )
    : [];
  const deliveryFiles = docs.filter((d) => d.type === "Delivery Evidence");
  const issueFiles = docs.filter((d) =>
    ["Issue / Review Evidence", "Cancellation Evidence", "Refund Review Evidence"].includes(d.type),
  );
  const currentScope = currentItem?.scope_snapshot
    ? [{ ...currentItem.scope_snapshot, quantity: 1 }]
    : [];
  const allItemsFinished = jobItems.length > 0 && finishedItems === jobItems.length;

  const receivingEvidence = (
    <Panel title="Receiving Evidence">
      <EvidenceGallery files={receivingFiles} />
      {role === "admin" && (
        <details open={!receivingFiles.length}>
          <summary>Add Receiving Evidence</summary>
          <EvidenceCapture
            config={{
              jobId: id,
              type: "Receiving Evidence",
              defaultVisibility: "internal",
            }}
          />
        </details>
      )}
    </Panel>
  );

  const currentItemPanel = currentItem ? (
    <>
      <Panel title={`${currentItem.display_label || `P${String(currentItem.sequence).padStart(3, "0")} · ${currentItem.article}`} · Item ${currentItem.sequence} of ${jobItems.length}`}>
        <p className="muted">
          {finishedItems}/{jobItems.length} items finished
        </p>
        {currentItem.stage === "Preparation" && (
          <>
            <p className="muted">Review the approved scope for this physical item before engraving.</p>
            <WorkPreparation items={currentScope as any} />
          </>
        )}

        {["Engraving", "Finished Evidence"].includes(currentItem.stage) && (
          <>
            <p>
              <strong>Stage:</strong>{" "}
              {currentItem.stage === "Finished Evidence" ? "Completed Evidence" : "Engraving"}
            </p>
            <EvidenceGallery files={itemEvidence} />
            {role === "admin" && currentItem.stage === "Engraving" && (
              <details open={!itemEvidence.length}>
                <summary>Add Completed Evidence for this item</summary>
                <EvidenceCapture
                  config={{
                    jobId: id,
                    jobItemId: currentItem.id,
                    type: "Production Evidence",
                    defaultVisibility: "customer",
                  }}
                />
              </details>
            )}
          </>
        )}
      </Panel>

      {activeCancellation ? (
        <p className="notice error">
          Cancellation request detected. Production is locked and this Job cannot continue.
        </p>
      ) : currentItem.stage === "Preparation" ? (
        <Form
          operation="job-item"
          hidden={{ item_id: currentItem.id, action: "next" }}
          fields={[]}
          back={`/app/jobs/${id}`}
          button="Next"
        />
      ) : currentItem.stage === "Finished Evidence" ? (
        <Form
          operation="job-item"
          hidden={{ item_id: currentItem.id, action: "finished" }}
          fields={[]}
          back={`/app/jobs/${id}`}
          button="Finished"
        />
      ) : null}
    </>
  ) : null;

  const cancelledWorkTab = (
    <>
      <Panel title="Job Cancelled">
        <p className="notice error">
          This Job has been cancelled. Production actions are locked.
        </p>
        {cancelledRequest && (
          <div className="grid two">
            <div>
              <small>Cancellation stage</small>
              <p><strong>{cancelledRequest.stage_at_request || "—"}</strong></p>
            </div>
            <div>
              <small>Engraving progress</small>
              <p>
                <strong>
                  {cancelledRequest.items_finished}/{cancelledRequest.items_total} items finished
                </strong>
              </p>
            </div>
            <div>
              <small>Cancellation charge</small>
              <p><strong>{money(cancelledRequest.service_charge_amount)}</strong></p>
            </div>
            <div>
              <small>Refund eligible</small>
              <p><strong>{money(cancelledRequest.refund_eligible_amount)}</strong></p>
            </div>
          </div>
        )}
      </Panel>

      {pendingPayment?.purpose === "Cancellation Balance" && (
        <Panel title="Cancellation payment verification">
          <p>
            <strong>{pendingPayment.method}</strong> · {money(pendingPayment.amount)} ·{" "}
            {paymentStatusLabel(pendingPayment.status)}
          </p>
          {pendingProofUrl && (
            <p>
              <a href={pendingProofUrl} target="_blank" rel="noreferrer">
                View payment proof →
              </a>
            </p>
          )}
          {role === "admin" && (
            <Form
              operation="confirm-payment"
              hidden={{ id: pendingPayment.id }}
              fields={[]}
              button="Confirm cancellation payment"
              back={`/app/jobs/${id}`}
            />
          )}
        </Panel>
      )}

      {cancelledRequest?.refund_status === "Pending" && (
        <Panel title="Refund pending">
          <p>
            Refund to issue:{" "}
            <strong>{money(cancelledRequest.refund_eligible_amount)}</strong>
          </p>
          <Link className="button" href="/app/refunds">
            Open Refunds
          </Link>
        </Panel>
      )}

      {pickupReturn?.pickup_status === "Picked Up" && (
        <Panel title="Return customer items">
          <p>
            ToolTag has this customer&apos;s items. Return status:{" "}
            <strong>{pickupReturn.return_status}</strong>.
          </p>
          {pickupReturn.hold_until_paid && (
            <p className="notice">
              Return is on hold until the cancellation balance is confirmed.
            </p>
          )}
          <Link className="button" href="/pick-return">
            Open Pick & Return
          </Link>
        </Panel>
      )}
    </>
  );

  const workTab = j.status === "Cancelled" ? cancelledWorkTab : (
    <>
      {stage === "Not Started" && !pickupReturn && (
        <>
          <Panel title="Start Job">
            <p className="muted">Start the receiving workflow for this Job.</p>
          </Panel>
          <Form
            operation="job"
            hidden={{ id, action: "start" }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button="Start Job"
          />
        </>
      )}

      {stage === "Not Started" && pickupReturn && (
        <Panel title="Pickup & Return">
          <p>
            Pickup fee: <strong>{money(pickupReturn.fee_amount)}</strong> · {pickupReturn.fee_status}
          </p>
          <p className="muted">
            This Job enters production automatically after Pickup receiving evidence is recorded and the items are marked Picked Up.
          </p>
          <Link className="button" href="/pick-return">
            Open Pick & Return
          </Link>
        </Panel>
      )}

      {stage === "Receiving Evidence" && (
        <>
          {receivingEvidence}
          <Form
            operation="job"
            hidden={{ id, action: "receiving-done" }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button="Next"
          />
        </>
      )}

      {["Preparing", "Engraving", "Final Evidence", "Final Details"].includes(stage) &&
        currentItemPanel}

      {stage === "Cancellation Requested / Production Hold" && (
        <Panel title="Cancellation Requested / Production Hold">
          <p className="notice error">
            Production is locked. Existing item progress and evidence have been preserved.
          </p>
          <p className="muted">
            No item can advance until the cancellation request is resolved.
          </p>
        </Panel>
      )}

      {["Preparing", "Engraving", "Final Evidence", "Final Details"].includes(stage) &&
        allItemsFinished &&
        !pickupReturn && (
          <Form
            operation="complete-job-work"
            hidden={{ id }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button="Ready for Delivery"
          />
        )}

      {stage === "Delivery In Progress" && pickupReturn && (
        <Panel title="Delivery in progress">
          <p>
            All {jobItems.length} items are finished. The Job is now in the Return workflow.
          </p>
          <p className="muted">
            Return status: {pickupReturn.return_status}
          </p>
          <Link className="button" href="/pick-return">
            Open Return Mode
          </Link>
        </Panel>
      )}

      {stage === "Awaiting Delivery Acceptance" && (
        <Panel title="Waiting for delivery acceptance">
          <p>
            The customer received the secure link to confirm receipt of the completed work.
          </p>
          {j.acceptance_deadline && (
            <p className="muted">
              Response deadline: {new Date(j.acceptance_deadline).toLocaleString("en-US")}
            </p>
          )}
        </Panel>
      )}

      {stage === "Issue Review" && (
        <Panel title="Issue / Review">
          <p>The customer reported an issue. This Job requires review before continuing.</p>
        </Panel>
      )}

      {stage === "Payment" && (
        <Panel title="Payment pending">
          <p>Delivery was accepted. The customer must complete the payment step.</p>
        </Panel>
      )}

      {stage === "Payment Verification" && (
        <Panel title="Payment verification">
          {pendingPayment ? (
            <>
              <p>
                <strong>{pendingPayment.method}</strong> · {money(pendingPayment.amount)} · {paymentStatusLabel(pendingPayment.status)}
              </p>
              {pendingProofUrl && (
                <p>
                  <a href={pendingProofUrl} target="_blank" rel="noreferrer">
                    View payment proof →
                  </a>
                </p>
              )}
              {role === "admin" && (
                <Form
                  operation="confirm-payment"
                  hidden={{ id: pendingPayment.id }}
                  fields={[]}
                  button="Confirm payment received"
                  back={`/app/jobs/${id}`}
                />
              )}
            </>
          ) : (
            <p>Payment is pending verification.</p>
          )}
        </Panel>
      )}

      {stage === "Closed" && (
        <Panel title="Completed">
          <p className="notice success">Delivery accepted and payment confirmed.</p>
        </Panel>
      )}
    </>
  );

  const detailsTab = (
    <>
      <JobLifecycle id={id} section="customer" />
      <Panel title="Trabajo aprobado">
        <QuoteScope items={scope} />
      </Panel>
    </>
  );

  const commercialTab = (
    <>
      <JobLifecycle id={id} section="commercial" />
      <Panel title="Venta y cobros">
        {sales.length ? (
          sales.map((s) => (
            <p key={s.transaction_id}>
              <Link href={`/app/finance/sales/${s.transaction_id}`}>
                {s.code} · {s.status} →
              </Link>
            </p>
          ))
        ) : (
          <p>Sin ventas registradas.</p>
        )}
      </Panel>
    </>
  );

  const evidenceTab = (
    <>
      <Panel title="Receiving Evidence">
        <EvidenceGallery files={receivingFiles} />
      </Panel>

      <Panel title="Production Evidence by Physical Item">
        {jobItems.length ? (
          <div className="stack">
            {jobItems.map((item) => {
              const files = docs.filter(
                (d) =>
                  ["Production Evidence", "Finished Evidence", "Completed Evidence"].includes(d.type) &&
                  d.job_item_id === item.id,
              );
              return (
                <div className="item" key={item.id}>
                  <div className="pick-return-row">
                    <div>
                      <strong>{item.display_label || `P${String(item.sequence).padStart(3, "0")} · ${item.article}`}</strong>
                      <p className="muted">{item.stage}</p>
                    </div>
                    <Badge>{files.length} file{files.length === 1 ? "" : "s"}</Badge>
                  </div>
                  <EvidenceGallery files={files} />
                </div>
              );
            })}
          </div>
        ) : (
          <Empty>No physical Job Items are available.</Empty>
        )}
      </Panel>

      <Panel title="Delivery Evidence">
        <EvidenceGallery files={deliveryFiles} />
      </Panel>

      <Panel title="Issue / Review Evidence">
        <EvidenceGallery files={issueFiles} />
        {role === "admin" && (
          <details>
            <summary>Add Issue / Review Evidence</summary>
            <EvidenceUpload
              config={{
                jobId: id,
                type: "Issue / Review Evidence",
                defaultVisibility: "internal",
              }}
              button="Upload File"
            />
          </details>
        )}
      </Panel>
    </>
  );

  const deliveryTab = (
    <>
      <AcceptedDocuments jobId={id} />
      <JobLifecycle id={id} section="delivery" />
    </>
  );

  const activityTab = <JobLifecycle id={id} section="activity" />;

  return (
    <>
      <Heading
        title={
          <span className="job-title-inline">
            <span>{j.code}</span>
            <Badge>{workStageLabel(stage)}</Badge>
          </span>
        }
      >
        <Link className="button secondary" href={`/app/quotes/${j.quote_id}`}>
          Cotización aprobada
        </Link>
      </Heading>

      <JobTabs
        defaultTab="work"
        tabs={[
          { id: "work", label: "Trabajo", content: workTab },
          { id: "details", label: "Detalles", content: detailsTab },
          { id: "commercial", label: "Comercial", content: commercialTab },
          { id: "evidence", label: "Evidence", content: evidenceTab },
          { id: "delivery", label: "Entrega", content: deliveryTab },
          { id: "activity", label: "Actividad", content: activityTab },
        ]}
      />
    </>
  );
}
