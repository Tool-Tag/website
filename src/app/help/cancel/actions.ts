"use server";

import { createHash } from "node:crypto";
import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase/server";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";

export type CancelAccessState = {
  error?: string;
  matched?: boolean;
  submitted?: boolean;
};

function serviceClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Cancellation service is not configured.");
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function networkFingerprint() {
  const h = await headers();
  const raw =
    h.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    h.get("x-real-ip") ||
    "unknown";
  return createHash("sha256").update(raw).digest("hex");
}

export async function requestCancellationAccess(
  _state: CancelAccessState,
  form: FormData,
): Promise<CancelAccessState> {
  try {
    const name = String(form.get("name") ?? "").trim();
    const email = String(form.get("email") ?? "").trim();
    const phone = String(form.get("phone") ?? "").trim();

    if (!name || !email || !phone) {
      return { error: "Enter your name, email, and phone number." };
    }

    const db = serviceClient();
    const { data, error } = await db.rpc("request_cancellation_access", {
      p_network: await networkFingerprint(),
      p_name: name,
      p_email: email,
      p_phone: phone,
    });

    if (error) return { error: error.message };

    if (data?.matched) {
      await dispatchWorkerMail();
      return { submitted: true, matched: true };
    }

    return { submitted: true, matched: false };
  } catch (error) {
    return {
      error: error instanceof Error ? error.message : "Unable to check your services.",
    };
  }
}

export type SecureCancelState = {
  error?: string;
  ok?: boolean;
  data?: any;
};

export async function secureCancellationAction(
  token: string,
  kind: "quote" | "job-assess" | "job-confirm",
  id: string,
  _state: SecureCancelState,
  _form: FormData,
): Promise<SecureCancelState> {
  const db = await supabase();

  const result =
    kind === "quote"
      ? await db.rpc("public_cancel_quote", { p_token: token, p_quote: id })
      : kind === "job-assess"
        ? await db.rpc("public_cancellation_assessment", {
            p_token: token,
            p_job: id,
          })
        : await db.rpc("public_confirm_job_cancellation", {
            p_token: token,
            p_job: id,
          });

  if (result.error) return { error: result.error.message };

  if (kind !== "job-assess") {
    await dispatchWorkerMail();
    revalidatePath("/app", "layout");
  }

  return { ok: kind !== "job-assess", data: result.data };
}
