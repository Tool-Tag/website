"use server";

import { createHash } from "node:crypto";
import { revalidatePath } from "next/cache";
import { context } from "@/lib/domain/context";
import {
  TOOLTAG_FILES_BUCKET,
  storageObjectName,
} from "@/lib/storage/files";

export type EvidenceActionState = {
  ok?: boolean;
  error?: string;
  documentId?: string;
};

export type EvidenceRegistration = {
  jobId?: string;
  transactionId?: string;
  type:
    | "Receiving Evidence"
    | "Production Evidence"
    | "Delivery Evidence"
    | "Issue / Review Evidence"
    | "Cancellation Evidence"
    | "Refund Review Evidence"
    | "Customer Document"
    | "Receipt"
    | "Other";
  jobItemId?: string;
  pickReturnStopId?: string;
  jobExtensionId?: string;
  paymentRequestId?: string;
  cancellationRequestId?: string;
  defaultVisibility?: "internal" | "customer";
  back?: string;
  photoOnly?: boolean;
};

export async function registerEvidenceAction(
  config: EvidenceRegistration,
  _state: EvidenceActionState,
  form: FormData,
): Promise<EvidenceActionState> {
  try {
    const { db, unit, role } = await context();
    if (role !== "admin") return { error: "Administrative access required." };

    const file = form.get("file");
    if (!(file instanceof File) || file.size <= 0) {
      return { error: "Choose a file first." };
    }

    if (file.size > 3.5 * 1024 * 1024) {
      return { error: "Use a file 3.5 MB or smaller." };
    }

    if (config.photoOnly && !file.type.startsWith("image/")) {
      return { error: "Choose an image for photo evidence." };
    }

    const original = storageObjectName(file.name || "evidence-file");
    const bytes = new Uint8Array(await file.arrayBuffer());
    const fingerprint = createHash("sha256").update(bytes).digest("hex");

    const visibility = String(
      form.get("visibility") || config.defaultVisibility || "internal",
    );
    if (!["internal", "customer"].includes(visibility)) {
      return { error: "Choose a valid visibility." };
    }

    const notes = String(form.get("notes") || "").trim().slice(0, 2000);
    const { data, error } = await db.rpc("register_document_metadata", {
      p: {
        unit_id: unit,
        type: config.type,
        job_id: config.jobId ?? null,
        transaction_id: config.transactionId ?? null,
        job_item_id: config.jobItemId ?? null,
        pick_return_stop_id: config.pickReturnStopId ?? null,
        job_extension_id: config.jobExtensionId ?? null,
        payment_request_id: config.paymentRequestId ?? null,
        cancellation_request_id: config.cancellationRequestId ?? null,
        file_name: original,
        original_file_name: original,
        mime_type: file.type || "application/octet-stream",
        file_size: file.size,
        sha256: fingerprint,
        visibility,
        notes: notes || null,
      },
    });

    if (error || !data) {
      return { error: error?.message || "Could not create the document record." };
    }

    const documentId = String(data);
    const { data: current } = await db
      .from("documents")
      .select("storage_status,storage_bucket,storage_path")
      .eq("id", documentId)
      .eq("unit_id", unit)
      .single();

    if (current?.storage_status !== "stored") {
      const objectPath = `${unit}/documents/${documentId}/${original}`;
      const { error: uploadError } = await db.storage
        .from(TOOLTAG_FILES_BUCKET)
        .upload(objectPath, bytes, {
          contentType: file.type || "application/octet-stream",
          upsert: true,
        });

      if (uploadError) {
        await db.rpc("finish_document_storage", {
          p_id: documentId,
          p_bucket: TOOLTAG_FILES_BUCKET,
          p_path: objectPath,
          p_status: "failed",
          p_error: uploadError.message,
        });
        return { error: "Could not store the file in Supabase Storage." };
      }

      const { data: finalized, error: finalizeError } = await db.rpc(
        "finish_document_storage",
        {
          p_id: documentId,
          p_bucket: TOOLTAG_FILES_BUCKET,
          p_path: objectPath,
          p_status: "stored",
          p_error: null,
        },
      );

      if (finalizeError || !finalized) {
        await db.storage.from(TOOLTAG_FILES_BUCKET).remove([objectPath]);
        return { error: "The file upload could not be linked to its ToolTag record." };
      }
    }

    revalidatePath("/app", "layout");
    if (config.jobId) revalidatePath(`/app/jobs/${config.jobId}`);
    if (config.transactionId) {
      revalidatePath(`/app/finance/transactions/${config.transactionId}`);
    }
    revalidatePath("/pick-return");

    return { ok: true, documentId };
  } catch (error) {
    return {
      error:
        error instanceof Error ? error.message : "Could not upload the file.",
    };
  }
}
