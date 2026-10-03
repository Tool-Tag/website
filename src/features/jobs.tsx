import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
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
  const j = (await rows("jobs", { id }))[0];
  if (!j) return <Empty>Trabajo no encontrado.</Empty>;
  const [docs, sales] = await Promise.all([
    rows("documents", { field: "job_id", value: id }),
    rows("sale_balances", { field: "job_id", value: id }),
  ]);
  const action = ["Authorized", "Receiving Documentation"].includes(j.status)
    ? "start"
    : j.status === "In Process"
      ? "ready"
      : j.status === "Ready for Delivery"
        ? "deliver"
        : null;
  return (
    <>
      <Heading title={j.code}>
        <Badge>{j.status}</Badge>
        <Link className="button secondary" href={`/app/quotes/${j.quote_id}`}>
          Cotización aprobada
        </Link>
      </Heading>
      <Panel title="Siguiente paso">
        {action ? (
          <Form
            operation="job"
            hidden={{ id, action }}
            fields={[]}
            back={`/app/jobs/${id}`}
            button={
              action === "start"
                ? "Comenzar trabajo"
                : action === "ready"
                  ? "Marcar listo para entrega"
                  : "Registrar entrega y preparar enlace"
            }
          />
        ) : (
          <p>{j.completion_reason ?? j.status}</p>
        )}
        {j.status === "Delivered – Pending Customer Acceptance" &&
          !j.acceptance_deadline && (
            <>
              <p className="muted">
                El plazo de 3 días empieza cuando confirmas que entregaste el
                enlace al cliente. No se ha enviado ningún correo
                automáticamente.
              </p>
              <Form
                operation="notified"
                hidden={{ id }}
                fields={[]}
                button="Confirmar que entregué el enlace"
                back={`/app/jobs/${id}`}
              />
            </>
          )}
        {j.acceptance_deadline && (
          <p>
            Plazo de respuesta:{" "}
            {new Date(j.acceptance_deadline).toLocaleString("es-US")}
          </p>
        )}
      </Panel>
      <div className="grid two">
        {["Receiving Evidence", "Completed Evidence"].map((type) => (
          <Panel
            key={type}
            title={
              type === "Receiving Evidence"
                ? "Evidencia de recepción"
                : "Evidencia de trabajo terminado"
            }
          >
            {docs
              .filter((d) => d.type === type)
              .map((d) => (
                <p key={d.id}>
                  <a
                    href={`https://drive.google.com/file/d/${encodeURIComponent(d.drive_file_id)}/view`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {d.file_name} ↗
                  </a>
                </p>
              ))}
            {!docs.some((d) => d.type === type) && (
              <Empty>Sin evidencia registrada.</Empty>
            )}
            <details>
              <summary>Vincular archivo de Drive</summary>
              <p className="muted">
                Carga el archivo directamente en Drive y registra su ID. La
                integración de subida está pendiente.
              </p>
              <Form
                operation="document"
                hidden={{ job_id: id, type }}
                back={`/app/jobs/${id}`}
                fields={[
                  {
                    name: "file_name",
                    label: "Nombre",
                    required: true,
                    value: `${j.code}-${type === "Receiving Evidence" ? "Receiving" : "Completed"}-${String(docs.filter((d) => d.type === type).length + 1).padStart(2, "0")}.jpg`,
                  },
                  {
                    name: "drive_file_id",
                    label: "Drive File ID",
                    required: true,
                  },
                ]}
              />
            </details>
          </Panel>
        ))}
      </div>
      <Panel title="Venta y cobros">
        {sales.map((s) => (
          <p key={s.transaction_id}>
            <Link href={`/app/finance/sales/${s.transaction_id}`}>
              {s.code} · {s.status} →
            </Link>
          </p>
        ))}
      </Panel>
    </>
  );
}
