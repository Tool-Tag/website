import { EvidenceGallery } from "@/components/evidence-gallery";
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

  const [docs, sales, paymentRequests] = await Promise.all([
    rows("documents", { field: "job_id", value: id }),
    rows("sale_balances", { field: "job_id", value: id }),
    rows("payment_requests", { field: "job_id", value: id, order: "submitted_at" }),
  ]);

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
  const completedFiles = docs.filter((d) => d.type === "Completed Evidence");
  const stage = j.work_stage ?? "Not Started";
  const receivingEvidence = (
    <Panel title="Evidencia de cómo se recibió">
      <EvidenceGallery files={receivingFiles} />
      {role === "admin" && (
        <details>
          <summary>Administración: vincular archivo existente de Drive</summary>
          <p className="muted">
            Carga el archivo directamente en Drive y registra su ID. La integración
            de subida directa sigue pendiente.
          </p>
          <Form
            operation="document"
            hidden={{ job_id: id, type: "Receiving Evidence" }}
            back={`/app/jobs/${id}`}
            fields={[
              {
                name: "file_name",
                label: "Nombre",
                required: true,
                value: `${j.code}-Receiving-${String(receivingFiles.length + 1).padStart(2, "0")}.jpg`,
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
  );

  const completedEvidence = (
    <Panel title="Evidencia de trabajo terminado">
      <EvidenceGallery files={completedFiles} />
      {role === "admin" && (
        <details>
          <summary>Administración: vincular archivo existente de Drive</summary>
          <p className="muted">
            Carga el archivo directamente en Drive y registra su ID. La integración
            de subida directa sigue pendiente.
          </p>
          <Form
            operation="document"
            hidden={{ job_id: id, type: "Completed Evidence" }}
            back={`/app/jobs/${id}`}
            fields={[
              {
                name: "file_name",
                label: "Nombre",
                required: true,
                value: `${j.code}-Completed-${String(completedFiles.length + 1).padStart(2, "0")}.jpg`,
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
  );

  const workTab = (
    <>
      {stage === "Not Started" && (
        <Panel title="Comenzar trabajo">
          <p className="muted">
            Inicia el flujo operativo de este Job.
          </p>
          <Form
            operation="job"
            hidden={{ id, action: "start" }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button="Comenzar trabajo"
          />
        </Panel>
      )}

      {stage === "Receiving Evidence" && (
        <>
          {receivingEvidence}
          <Panel title="Siguiente paso">
            <p className="muted">
              Cuando la evidencia de recepción esté registrada, continúa a preparación.
            </p>
            <Form
              operation="job"
              hidden={{ id, action: "receiving-done" }}
              fields={[]}
              back={`/app/jobs/${id}`}
              button="Siguiente"
            />
          </Panel>
        </>
      )}

      {stage === "Preparing" && (
        <>
          <Panel title="Preparando">
            <p className="muted">
              Revisa aquí exactamente lo aprobado antes de comenzar el grabado.
            </p>
            <WorkPreparation items={scope} />
          </Panel>
          <Form
            operation="job"
            hidden={{ id, action: "preparation-done" }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button="Siguiente"
          />
        </>
      )}

      {["Final Evidence", "Final Details"].includes(stage) && (
        <>
          {completedEvidence}
          <Panel title="Terminar trabajo">
            <p className="muted">
              Al marcar Terminado se enviará al cliente la notificación con el enlace seguro para aceptar la entrega.
            </p>
            <Form
              operation="job"
              hidden={{ id, action: "finished" }}
              fields={[]}
              back={`/app/jobs/${id}`}
              button="Terminado"
            />
          </Panel>
        </>
      )}

      {stage === "Awaiting Delivery Acceptance" && (
        <Panel title="Esperando aceptación de entrega">
          <p>
            El cliente recibió el enlace seguro para confirmar que recibió el trabajo y está conforme.
          </p>
          {j.acceptance_deadline && (
            <p className="muted">
              Plazo de respuesta: {new Date(j.acceptance_deadline).toLocaleString("es-US")}
            </p>
          )}
        </Panel>
      )}


      {stage === "Issue Review" && (
        <Panel title="Incidencia / revisión">
          <p>
            El cliente reportó un problema con la entrega. Este Job requiere revisión antes de continuar.
          </p>
        </Panel>
      )}

      {stage === "Payment" && (
        <Panel title="Pago pendiente">
          <p>
            La entrega ya fue aceptada. El cliente debe completar el paso de pago.
          </p>
        </Panel>
      )}

      {stage === "Payment Verification" && (
        <Panel title="Pago pendiente de verificación">
          {pendingPayment ? (
            <>
              <p>
                <strong>{pendingPayment.method}</strong> · {money(pendingPayment.amount)} · {paymentStatusLabel(pendingPayment.status)}
              </p>
              {pendingProofUrl && (
                <p>
                  <a href={pendingProofUrl} target="_blank" rel="noreferrer">
                    Ver comprobante →
                  </a>
                </p>
              )}
              {role === "admin" && (
                <Form
                  operation="confirm-payment"
                  hidden={{ id: pendingPayment.id }}
                  fields={[]}
                  button="Confirmar pago recibido"
                  back={`/app/jobs/${id}`}
                />
              )}
            </>
          ) : (
            <p>El pago está pendiente de verificación.</p>
          )}
        </Panel>
      )}

      {stage === "Closed" && (
        <Panel title="Trabajo completado">
          <p className="notice success">Entrega aceptada y pago confirmado.</p>
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
          { id: "delivery", label: "Entrega", content: deliveryTab },
          { id: "activity", label: "Actividad", content: activityTab },
        ]}
      />
    </>
  );
}
