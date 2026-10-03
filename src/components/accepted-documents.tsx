import { context } from "@/lib/domain/context";
import { Panel } from "@/components/ui";
import { AcceptedDocumentActions } from "./accepted-document-actions";
export async function AcceptedDocuments({quoteId,jobId}:{quoteId?:string;jobId?:string}) {
  const {db,role,unit} = await context();
  const {data:documents,error} = await db.from("accepted_documents").select("id,quote_id,acceptance_folio,agreement_version,accepted_at,customer_recipient_email").eq("unit_id",unit).eq(quoteId ? "quote_id" : "job_id",quoteId || jobId!).order("accepted_at",{ascending:false});
  if (error || !documents?.length) return null;
  return <>{await Promise.all(documents.map(async d => {
    const [{data:status},{data:copies}] = await Promise.all([
      db.from("accepted_document_status").select("*").eq("document_id",d.id).single(),
      db.from("notifications").select("status,mail_error,payload").eq("entity_id",d.quote_id).contains("payload",{document_id:d.id}),
    ]);
    const copyStatus = (copy:string) => { const row = copies?.find(c => c.payload.copy===copy); return row ? `${row.status}${row.mail_error ? ` · ${row.mail_error}` : ""}` : "Pendiente"; };
    return <Panel key={d.id} title={`Agreement · ${d.acceptance_folio}`}>
      <p>Versión {d.agreement_version} · Aceptado: {new Date(d.accepted_at).toLocaleString("es-US")}</p>
      <p>Destinatario original: {d.customer_recipient_email}</p>
      <p>PDF: {status?.pdf_status || "Pendiente"}</p>
      <p>Copia cliente: {copyStatus("customer")}<br/>Copia ToolTag: {copyStatus("internal")}</p>
      <p>Drive: {status?.storage_status || "Pending Drive Upload"}</p>
      <p className="muted">En esta fase ambas copias van únicamente a quotes@tooltag.martinlab.studio. Sent significa aceptado por Gmail para entrega.</p>
      {status?.pdf_status === "Ready" && <p><a href={`/app/accepted-documents/${d.id}/pdf`} target="_blank" rel="noreferrer">Ver / descargar Agreement PDF</a></p>}
      {role === "admin" && <AcceptedDocumentActions id={d.id} back={quoteId ? `/app/quotes/${quoteId}` : `/app/jobs/${jobId}`}/>}
    </Panel>;
  }))}</>;
}
