"use server";

import { createHash } from "node:crypto";
import { revalidatePath } from "next/cache";
import { context } from "@/lib/domain/context";

export type EvidenceActionState = {
  ok?: boolean;
  error?: string;
  documentId?: string;
  warning?: string;
};

export type EvidenceRegistration = {
  jobId: string;
  type:
    | "Receiving Evidence"
    | "Production Evidence"
    | "Delivery Evidence"
    | "Issue / Review Evidence"
    | "Cancellation Evidence"
    | "Refund Review Evidence"
    | "Customer Document"
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

function safeName(value: string) {
  return value
    .replace(/[\\/\0\r\n\t]/g, "_")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
}

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

    if (file.size > 25 * 1024 * 1024) {
      return { error: "Use a file 25 MB or smaller." };
    }

    if (config.photoOnly && !file.type.startsWith("image/")) {
      return { error: "Choose an image for photo evidence." };
    }

    const original = safeName(file.name || "evidence-file");
    if (!original) return { error: "The file name is invalid." };

    const bytes = new Uint8Array(await file.arrayBuffer());
    const fingerprint = createHash("sha256")
      .update(bytes)
      .digest("hex");

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
        job_id: config.jobId,
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

    if (error) return { error: error.message };

    revalidatePath("/app", "layout");
    revalidatePath(`/app/jobs/${config.jobId}`);
    revalidatePath("/pick-return");

    return {
      ok: true,
      documentId: String(data),
      warning:
        "Evidence metadata is saved in ToolTag. The file bytes are not stored yet; storage remains Pending Drive Upload until Google Drive is connected.",
    };
  } catch (error) {
    return {
      error:
        error instanceof Error ? error.message : "Could not register evidence.",
    };
  }
}
