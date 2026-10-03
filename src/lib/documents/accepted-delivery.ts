import { createHash } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { generateAcceptedPdf, type AcceptedDocument } from "./accepted-pdf";
import { GmailTransport, mailEnabled, MailFailure } from "@/lib/integrations/gmail";
import { renderNotification } from "@/lib/integrations/notification-mail";
import { money } from "@/lib/domain/money";
export const ACCEPTED_TEST_RECIPIENT = "quotes@tooltag.martinlab.studio";
export async function processAcceptedDocument(db: SupabaseClient, id: string) {
  const {data: document, error: readError} = await db.from("accepted_documents").select("*").eq("id", id).single();
  if (readError || !document) return "No se pudo cargar el documento aceptado.";
  const d = document as AcceptedDocument;
  const {data: claimed, error: claimError} = await db.rpc("claim_accepted_pdf", {p_id: id});
  if (claimError) return "No se pudo preparar el PDF.";
  if (claimed) {
    let bytes: Buffer;
    try {
      if (createHash("sha256").update(claimed.canonical_snapshot, "utf8").digest("hex") !== claimed.acceptance_snapshot_sha256) throw new Error("Snapshot integrity failure");
      bytes = await generateAcceptedPdf(claimed as AcceptedDocument);
      if (bytes.length > 4000000) throw new Error("PDF size limit exceeded");
    } catch {
      await db.rpc("finish_accepted_pdf", {p_id: id, p_claim: claimed.claim, p_error: "PDF_GENERATION_FAILED"});
      return "La aceptación sigue válida. Falló la generación del PDF; puedes reintentar.";
    }
    const {data: saved, error} = await db.rpc("finish_accepted_pdf", {p_id:id, p_claim:claimed.claim, p_pdf:bytes.toString("base64")});
    if (error || !saved) return "No se confirmó el guardado del PDF. Revisa su estado antes de reintentar.";
  }
  // This phase is test-only. Never override a live/disabled environment to send mail.
  if (process.env.TOOLTAG_MAIL_MODE !== "test-delivery" || process.env.TOOLTAG_MAIL_TEST_RECIPIENT?.toLowerCase() !== ACCEPTED_TEST_RECIPIENT || !mailEnabled())
    return "PDF preparado o en proceso. Las copias esperan el modo de prueba con quotes@tooltag.martinlab.studio.";
  const {data: artifact, error: fileError} = await db.rpc("accepted_pdf_file", {p_id:id});
  if (fileError || !artifact) return "PDF pendiente de generación. La aceptación permanece válida.";
  // Load the stored bytes once and reuse the same buffer for both independent copies.
  const pdf = Buffer.from(artifact.pdf, "base64");
  if (createHash("sha256").update(pdf).digest("hex") !== artifact.sha256) return "No se pudo verificar la integridad del PDF.";
  let delivered = 0;
  for (const copy of ["customer", "internal"] as const) {
    const {data:event, error} = await db.rpc("claim_accepted_copy", {p_id:id,p_copy:copy});
    if (error) return "No se pudo preparar la copia del correo.";
    if (!event) continue;
    let provider: string | null = null, failure: string | null = null;
    try {
      const s = d.snapshot;
      const subject = copy === "customer"
        ? `[TEST CUSTOMER COPY] Your Accepted ToolTag Agreement — ${d.acceptance_folio}`
        : `[TEST TOOLTAG COPY] Accepted Agreement Copy — ${d.acceptance_folio} — ${s.customer_name}`;
      const text = `Quote and Agreement accepted.\nCustomer: ${s.customer_name}\nQuote: ${s.quote_code} / revision ${s.quote_revision}\nJob: ${s.job_code}\nAgreement Folio: ${d.acceptance_folio}\nAgreed total: ${money(String(s.total))}\n\nYour accepted PDF is attached for your records.\n\nTEST ONLY: both copies are sent to ToolTag. Intended quote recipient: ${s.customer_email}`;
      const message = renderNotification(subject, text, ACCEPTED_TEST_RECIPIENT, "AGREEMENT_ACCEPTED");
      message.attachments = [{filename:d.file_name,content:pdf}];
      provider = (await new GmailTransport().deliver(message,event.dedupe_key)).providerId;
    } catch (error) { failure = error instanceof MailFailure ? error.code : "ACCEPTED_MAIL_FAILED"; }
    const {data: finished, error: finishError} = await db.rpc("finish_quote_mail", {p_id:event.id,p_claim:event.mail_claim,p_provider_id:provider,p_error:failure});
    if (finishError || !finished) return "El resultado de correo requiere revisión antes de reintentar.";
    if (provider) delivered++;
  }
  return delivered ? `${delivered} copia(s) de prueba aceptada(s) por Gmail para quotes@tooltag.martinlab.studio.` : "Consulta el estado de cada copia. El PDF y el folio se conservan.";
}
export async function processAcceptedQueue(db: SupabaseClient) {
  const {data, error} = await db.rpc("pending_accepted_documents");
  if (error) return;
  for (const item of data || []) {
    try { await processAcceptedDocument(db, item.document_id); }
    catch { /* Durable claims remain visible and require reconciliation/retry. */ }
  }
}
export async function processAcceptedWorker() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY, url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!key || !url) return;
  try { await processAcceptedQueue(createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}})); }
  catch { /* Acceptance is committed independently; admin can process the document. */ }
}
