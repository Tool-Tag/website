import { Form } from "./form";
import { context } from "@/lib/domain/context";
import { Panel } from "@/components/ui";
import { AcceptedDocumentActions } from "./accepted-document-actions";
import { storageStatusLabel } from "@/lib/storage/files";

export async function AcceptedDocuments({
  quoteId,
  jobId,
}: {
  quoteId?: string;
  jobId?: string;
}) {
  const { db, role, unit } = await context();
  const { data: documents, error } = await db
    .from("accepted_documents")
    .select(
      "id,quote_id,acceptance_folio,agreement_version,accepted_at,customer_recipient_email",
    )
    .eq("unit_id", unit)
    .eq(quoteId ? "quote_id" : "job_id", quoteId || jobId!)
    .order("accepted_at", { ascending: false });

  if (error) {
    return (
      <Panel title="Agreement PDF">
        <p>The accepted-document migration still needs to be applied.</p>
      </Panel>
    );
  }

  if (!documents?.length) {
    const { data: agreements } = await db
      .from("agreements")
      .select("quote_id,commercial_snapshot")
      .eq(quoteId ? "quote_id" : "job_id", quoteId || jobId!);
    if (role !== "admin" || !agreements?.length) return null;
    return (
      <Panel title="Prepare Existing Acceptance Document">
        <p>
          The existing accepted record will be used without creating another Job,
          Sale, or acceptance. Historical copies will not be sent automatically.
        </p>
        {agreements
          .filter((a) => a.commercial_snapshot)
          .map((a) => (
            <Form
              key={a.quote_id}
              operation="prepare-accepted-document"
              hidden={{ quote_id: a.quote_id }}
              fields={[]}
              button="Prepare PDF for This Acceptance"
              back={
                quoteId ? `/app/quotes/${quoteId}` : `/app/jobs/${jobId}`
              }
            />
          ))}
      </Panel>
    );
  }

  return (
    <>
      {await Promise.all(
        documents.map(async (d) => {
          const [{ data: status }, { data: copies }] = await Promise.all([
            db
              .from("accepted_document_status")
              .select("*")
              .eq("document_id", d.id)
              .single(),
            db
              .from("notifications")
              .select("status,mail_error,payload")
              .eq("entity_id", d.quote_id)
              .contains("payload", { document_id: d.id }),
          ]);
          const copyStatus = (copy: string) => {
            const row =
              copies?.find(
                (c) => c.payload.copy === copy && c.payload.test === false,
              ) || copies?.find((c) => c.payload.copy === copy);
            return row
              ? `${row.status}${row.mail_error ? ` · ${row.mail_error}` : ""}`
              : "Pending";
          };
          const storageLabel =
            status?.storage_status === "Pending Drive Upload" &&
            status?.pdf_status === "Ready"
              ? "Historical PDF artifact"
              : storageStatusLabel(status?.storage_status, "supabase_storage");

          return (
            <Panel key={d.id} title={`Agreement · ${d.acceptance_folio}`}>
              <p>
                Version {d.agreement_version} · Accepted:{" "}
                {new Date(d.accepted_at).toLocaleString("en-US")}
              </p>
              <p>Original Recipient: {d.customer_recipient_email}</p>
              <p>PDF: {status?.pdf_status || "Pending"}</p>
              <p>
                Customer copy: {copyStatus("customer")}
                <br />
                ToolTag copy: {copyStatus("internal")}
              </p>
              <p>Storage: {storageLabel}</p>
              <p className="muted">
                Both copies use the same PDF. Historical documents require explicit
                authorization for real delivery. Sent means Gmail accepted the
                message for delivery.
              </p>
              {status?.pdf_status === "Ready" && (
                <p>
                  <a
                    href={`/app/accepted-documents/${d.id}/pdf`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Ver / descargar Agreement PDF
                  </a>
                </p>
              )}
              {role === "admin" && (
                <AcceptedDocumentActions
                  id={d.id}
                  back={
                    quoteId
                      ? `/app/quotes/${quoteId}`
                      : `/app/jobs/${jobId}`
                  }
                />
              )}
            </Panel>
          );
        }),
      )}
    </>
  );
}
