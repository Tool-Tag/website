import { Form } from "./form";
import { context } from "@/lib/domain/context";
import { Panel } from "@/components/ui";
import { AcceptedDocumentActions } from "./accepted-document-actions";
export async function AcceptedDocuments({quoteId,jobId}:{quoteId?:string;jobId?:string}) {
  const {db,role,unit} = await context();
  const {data:documents,error} = await db.from("accepted_documents").select("id,quote_id,acceptance_folio,agreement_version,accepted_at,customer_recipient_email").eq("unit_id",unit).eq(quoteId ? "quote_id" : "job_id",quoteId || jobId!).order("accepted_at",{ascending:false});
  if (error) return <Panel title="Agreement PDF"><p>La migración del documento aceptado está pendiente de aplicar.</p></Panel>;
  if (!documents?.length) {
    const {data:agreements}=await db.from("agreements").select("quote_id,commercial_snapshot").eq(quoteId ? "quote_id" : "job_id",quoteId || jobId!);
    if(role!=="admin" || !agreements?.length) return null;
    return <Panel title="Preparar documento de aceptación existente"><p>Se usará el registro aceptado, sin crear otro Job, Sale o aceptación. No enviará copias históricas automáticamente.</p>{agreements.filter(a=>a.commercial_snapshot).map(a=><Form key={a.quote_id} operation="prepare-accepted-document" hidden={{quote_id:a.quote_id}} fields={[]} button="Preparar PDF de esta aceptación" back={quoteId ? `/app/quotes/${quoteId}` : `/app/jobs/${jobId}`}/>)}</Panel>;
  }
  return <>{await Promise.all(documents.map(async d => {
    const [{data:status},{data:copies}] = await Promise.all([
      db.from("accepted_document_status").select("*").eq("document_id",d.id).single(),
      db.from("notifications").select("status,mail_error,payload").eq("entity_id",d.quote_id).contains("payload",{document_id:d.id}),
    ]);
    const copyStatus = (copy:string) => { const row = copies?.find(c => c.payload.copy===copy && c.payload.test === false) || copies?.find(c => c.payload.copy===copy); return row ? `${row.status}${row.mail_error ? ` · ${row.mail_error}` : ""}` : "Pendiente"; };
    return <Panel key={d.id} title={`Agreement · ${d.acceptance_folio}`}>
      <p>Versión {d.agreement_version} · Aceptado: {new Date(d.accepted_at).toLocaleString("es-US")}</p>
      <p>Destinatario original: {d.customer_recipient_email}</p>
      <p>PDF: {status?.pdf_status || "Pendiente"}</p>
      <p>Copia cliente: {copyStatus("customer")}<br/>Copia ToolTag: {copyStatus("internal")}</p>
      <p>Drive: {status?.storage_status || "Pending Drive Upload"}</p>
      <p className="muted">Las copias usan el mismo PDF. Los documentos históricos requieren autorización explícita para un envío real. Sent significa aceptado por Gmail para entrega.</p>
      {status?.pdf_status === "Ready" && <p><a href={`/app/accepted-documents/${d.id}/pdf`} target="_blank" rel="noreferrer">Ver / descargar Agreement PDF</a></p>}
      {role === "admin" && <AcceptedDocumentActions id={d.id} back={quoteId ? `/app/quotes/${quoteId}` : `/app/jobs/${jobId}`}/>}
    </Panel>;
  }))}</>;
}
