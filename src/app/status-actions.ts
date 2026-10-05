"use server";

import { revalidatePath } from "next/cache";
import { supabase } from "@/lib/supabase/server";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
import type { ActionState } from "@/app/actions";

export async function statusCancellationAction(
  token: string,
  mode: "assess" | "confirm",
  _state: ActionState,
  _form: FormData,
): Promise<ActionState> {
  const db = await supabase();
  const result =
    mode === "assess"
      ? await db.rpc("public_status_cancellation_assessment", { p_token: token })
      : await db.rpc("public_status_confirm_cancellation", { p_token: token });

  if (result.error) return { error: result.error.message };

  if (mode === "confirm") {
    await dispatchWorkerMail();
    revalidatePath(`/status/${token}`);
    revalidatePath("/app", "layout");
    return { ok: true, data: result.data };
  }

  return { data: result.data };
}
