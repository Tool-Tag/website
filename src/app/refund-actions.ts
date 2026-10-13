"use server";
import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/domain/context";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
export type RefundState = {
    ok?: boolean;
    error?: string;
};
export async function refundAction(kind: "create" | "confirm" | "complete" | "cancel", id: string, _state: RefundState, form: FormData): Promise<RefundState> {
    try {
        const { db } = await requirePermission("payments.refund");
        const fields = Object.fromEntries([...form.entries()].filter(([, v]) => typeof v === "string"));
        const { data, error } = await db.rpc(kind === "create" ? "create_refund_request" : "refund_request_action", { p: { ...fields, id, action: kind, reviewed: form.get("reviewed") === "on", request_key: id } });
        if (error)
            return { error: error.message };
        revalidatePath("/app/finance/refunds");
        revalidatePath("/app/refunds");
        if (fields.job_id || data?.job_id)
            revalidatePath(`/app/jobs/${fields.job_id || data.job_id}`);
        if (kind === "complete")
            await Promise.allSettled([dispatchWorkerMail()]);
        return { ok: true };
    }
    catch (error) {
        return { error: error instanceof Error ? error.message : "Unable to save refund." };
    }
}
