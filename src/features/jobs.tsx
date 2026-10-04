import { EvidenceGallery } from "@/components/evidence-gallery";
import { JobLifecycle } from "@/components/job-lifecycle";
import { JobTabs } from "@/components/job-tabs";
import { AcceptedDocuments } from "@/components/accepted-documents";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
import { QuoteScope } from "@/components/quote-scope";
import { Form } from "@/components/form";

export async function Jobs({ id }: { id?: string }) {
  if (!id) {
    const list = await rows("jobs", { order: "created_at" });
    return (
      <>
        <Heading
          title="Trabajos"
          subtitle="Se crean al aceptar la cotización y los términos."
        />
        <Panel>
          {list.length ? (
            <Table headers={["Trabajo", "Estado", "Creado"]}>
              {list.map((j) => (
                <tr key={j.id}>
                  <td>
                    <Link href={`/app/jobs/${j.id}`}>{j.code}</Link>
                  </td>
                  <td>
                    <Badge>{j.status}</Badge>
                  </td>
                  <td>{new Date(j.created_at).toLocaleDateString("es-US")}</td>
                </tr>
              ))}
            </Table>
          ) : (
            <Empty />
          )}
        </Panel>
      </>
    );
  }

  const { role } = await context();
  const j = (await rows("jobs", { id }))[0];
  if (!j) return <Empty>Trabajo no encontrado.</Empty>;

  const [docs, sales] = await Promise.all([
    rows("documents", { field: "job_id", value: id }),
    rows("sale_balances", { field: "job_id", value: id }),
  ]);

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
            <QuoteScope items={scope} />
          </Panel>
          <Panel title="Siguiente paso">
            <p className="muted">
              Al continuar, el Job pasará a grabado y después deberás registrar la evidencia final.
            </p>
            <Form
              operation="job"
              hidden={{ id, action: "preparation-done" }}
              fields={[]}
              back={`/app/jobs/${id}`}
              button="Siguiente"
            />
          </Panel>
        </>
      )}

      {stage === "Final Evidence" && (
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

      {stage === "Payment" && (
        <Panel title="Pago pendiente">
          <p>
            La entrega ya fue aceptada. El cliente debe completar el paso de pago.
          </p>
        </Panel>
      )}

      {stage === "Payment Verification" && (
        <Panel title="Pago pendiente de verificación">
          <p>
            El cliente ya envió su forma de pago. Revisa y confirma el pago en la pestaña Comercial.
          </p>
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
            <Badge>{stage}</Badge>
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
