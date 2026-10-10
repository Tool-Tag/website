import { createHash } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { generateAcceptedPdf, type AcceptedDocument } from "./accepted-pdf";
import {
  GmailTransport,
  mailEnabled,
  MailFailure,
} from "@/lib/integrations/gmail";
import { renderNotification } from "@/lib/integrations/notification-mail";
import { money } from "@/lib/domain/money";
import { TOOLTAG_FILES_BUCKET } from "@/lib/storage/files";

export const ACCEPTED_TEST_RECIPIENT = "quotes@tooltag.martinlab.studio";

async function acceptedPdfBytes(
  db: SupabaseClient,
  artifact: Record<string, unknown>,
) {
  if (
    typeof artifact.storage_bucket === "string" &&
    typeof artifact.storage_path === "string"
  ) {
    const { data, error } = await db.storage
      .from(artifact.storage_bucket)
      .download(artifact.storage_path);
    if (error || !data) throw new Error("ACCEPTED_PDF_STORAGE_READ_FAILED");
    return Buffer.from(await data.arrayBuffer());
  }

  if (typeof artifact.pdf === "string") {
    return Buffer.from(artifact.pdf, "base64");
  }

  throw new Error("ACCEPTED_PDF_UNAVAILABLE");
}

export async function processAcceptedDocument(db: SupabaseClient, id: string) {
  const { data: document, error: readError } = await db
    .from("accepted_documents")
    .select("*")
    .eq("id", id)
    .single();
  if (readError || !document) {
    return "The accepted document could not be loaded.";
  }

  const d = document as AcceptedDocument;
  const { data: claimed, error: claimError } = await db.rpc(
    "claim_accepted_pdf",
    { p_id: id },
  );
  if (claimError) return "The PDF could not be prepared.";

  if (claimed) {
    let bytes: Buffer;
    try {
      if (
        createHash("sha256")
          .update(claimed.canonical_snapshot, "utf8")
          .digest("hex") !== claimed.acceptance_snapshot_sha256
      ) {
        throw new Error("Snapshot integrity failure");
      }
      bytes = await generateAcceptedPdf(claimed as AcceptedDocument);
      if (bytes.length > 4000000) throw new Error("PDF size limit exceeded");
    } catch {
      await db.rpc("finish_accepted_pdf_storage", {
        p_id: id,
        p_claim: claimed.claim,
        p_bucket: null,
        p_path: null,
        p_sha256: null,
        p_error: "PDF_GENERATION_FAILED",
      });
      return "The acceptance remains valid. PDF generation failed; you can retry.";
    }

    const hash = createHash("sha256").update(bytes).digest("hex");
    const objectPath = `${claimed.unit_id}/accepted-documents/${id}.pdf`;
    const { error: uploadError } = await db.storage
      .from(TOOLTAG_FILES_BUCKET)
      .upload(objectPath, bytes, {
        contentType: "application/pdf",
        upsert: true,
      });

    if (uploadError) {
      await db.rpc("finish_accepted_pdf_storage", {
        p_id: id,
        p_claim: claimed.claim,
        p_bucket: null,
        p_path: null,
        p_sha256: null,
        p_error: "STORAGE_UPLOAD_FAILED",
      });
      return "The acceptance remains valid. PDF Storage upload failed; you can retry.";
    }

    const { data: saved, error } = await db.rpc(
      "finish_accepted_pdf_storage",
      {
        p_id: id,
        p_claim: claimed.claim,
        p_bucket: TOOLTAG_FILES_BUCKET,
        p_path: objectPath,
        p_sha256: hash,
        p_error: null,
      },
    );

    if (error || !saved) {
      await db.storage.from(TOOLTAG_FILES_BUCKET).remove([objectPath]);
      return "The PDF Storage result could not be confirmed. Review its status before retrying.";
    }
  }

  const mode = process.env.TOOLTAG_MAIL_MODE;
  if (!mailEnabled() || !["live", "test-delivery"].includes(mode || "")) {
    return "PDF prepared. Email delivery is not enabled yet.";
  }
  if (
    mode === "test-delivery" &&
    process.env.TOOLTAG_MAIL_TEST_RECIPIENT?.toLowerCase() !==
      ACCEPTED_TEST_RECIPIENT
  ) {
    return "Configure the Agreement test recipient.";
  }

  const { data: artifact, error: fileError } = await db.rpc(
    "accepted_pdf_file",
    { p_id: id },
  );
  if (fileError || !artifact) {
    return "PDF generation is pending. The acceptance remains valid.";
  }

  let pdf: Buffer;
  try {
    pdf = await acceptedPdfBytes(db, artifact as Record<string, unknown>);
  } catch {
    return "The accepted PDF could not be loaded from Storage.";
  }

  if (createHash("sha256").update(pdf).digest("hex") !== artifact.sha256) {
    return "The PDF integrity could not be verified.";
  }

  let delivered = 0;
  for (const copy of ["customer", "internal"] as const) {
    const { data: event, error } = await db.rpc("claim_document_copy", {
      p_id: id,
      p_copy: copy,
      p_mode: mode,
    });
    if (error) return "The email copy could not be prepared.";
    if (!event) continue;

    let provider: string | null = null;
    let failure: string | null = null;
    try {
      const s = d.snapshot;
      const subject =
        copy === "customer"
          ? `${mode === "test-delivery" ? "[TEST CUSTOMER COPY] " : ""}Your Accepted ToolTag Agreement — ${d.acceptance_folio}`
          : `${mode === "test-delivery" ? "[TEST TOOLTAG COPY] " : ""}Accepted Agreement Copy — ${d.acceptance_folio} — ${s.customer_name}`;
      const text = `Quote and Agreement accepted.\nCustomer: ${s.customer_name}\nQuote: ${s.quote_code} / revision ${s.quote_revision}\nJob: ${s.job_code}\nAgreement Folio: ${d.acceptance_folio}\nAgreed total: ${money(String(s.total))}\n\nYour accepted PDF is attached for your records.${mode === "test-delivery" ? `\n\nTEST ONLY. Original quote recipient: ${s.customer_email}` : ""}`;
      const message = renderNotification(
        subject,
        text,
        event.recipient,
        "AGREEMENT_ACCEPTED",
      );
      message.attachments = [{ filename: d.file_name, content: pdf }];
      provider = (
        await new GmailTransport().deliver(message, event.dedupe_key)
      ).providerId;
    } catch (error) {
      failure =
        error instanceof MailFailure ? error.code : "ACCEPTED_MAIL_FAILED";
    }

    const { data: finished, error: finishError } = await db.rpc(
      "finish_quote_mail",
      {
        p_id: event.id,
        p_claim: event.mail_claim,
        p_provider_id: provider,
        p_error: failure,
      },
    );
    if (finishError || !finished) {
      return "The email result requires review before retrying.";
    }
    if (provider) delivered++;
  }

  return delivered
    ? `${delivered} copy/copies accepted by Gmail for delivery.`
    : "Review each copy status. The PDF and acceptance folio are preserved.";
}

export async function processAcceptedQueue(db: SupabaseClient) {
  const { data, error } = await db.rpc("pending_accepted_documents");
  if (error) return;
  for (const item of data || []) {
    try {
      await processAcceptedDocument(db, item.document_id);
    } catch {
      /* Durable claims remain visible and require reconciliation/retry. */
    }
  }
}

export async function processAcceptedWorker() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!key || !url) return;
  try {
    await processAcceptedQueue(
      createClient(url, key, {
        auth: { persistSession: false, autoRefreshToken: false },
      }),
    );
  } catch {
    /* Acceptance is committed independently; admin can process the document. */
  }
}
