"use server";

import { createHash } from "node:crypto";
import { headers } from "next/headers";
import { createClient } from "@supabase/supabase-js";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
import { z } from "zod";

export type CancellationLookupState = {
  ok?: boolean;
  matched?: boolean;
  message?: string;
  error?: string;
};

export async function requestCancellationAccess(
  _: CancellationLookupState,
  form: FormData,
): Promise<CancellationLookupState> {
  const parsed = z
    .object({
      name: z.string().trim().min(1),
      email: z.email(),
      phone: z.string().trim().min(7),
    })
    .safeParse({
      name: String(form.get("name") ?? ""),
      email: String(form.get("email") ?? "").trim(),
      phone: String(form.get("phone") ?? ""),
    });

  if (!parsed.success) {
    return { error: "Verify your name, email, and phone number and try again." };
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return { error: "Cancellation service is not configured." };

  const h = await headers();
  const forwarded = h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const network = createHash("sha256").update(forwarded).digest("hex");

  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin.rpc("request_cancellation_access", {
    p_network: network,
    p_name: parsed.data.name,
    p_email: parsed.data.email,
    p_phone: parsed.data.phone,
  });

  if (error) return { error: error.message };

  if (data?.matched) {
    await dispatchWorkerMail();
    return {
      ok: true,
      matched: true,
      message: "Your cancellation details have been sent to your email.",
    };
  }

  return {
    ok: true,
    matched: false,
    message:
      "We couldn’t find an active ToolTag service matching the information provided. Please verify your details and try again, or contact ToolTag Support.",
  };
}
