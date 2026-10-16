"use server";
import {validateRefundIssueAmount} from "@/lib/domain/refund-flow";
import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/domain/context";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
export type RefundState = {
    ok?: boolean;
    error?: string;
};
export async function refundAction(kind: "create" | "review" | "approve" | "confirm" | "complete" | "cancel" | "reject" | "acknowledge" | "note", id: string, _state: RefundState, form: FormData): Promise<RefundState> {
    try {
        const { db, unit } = await requirePermission("payments.refund");
        const fields = Object.fromEntries([...form.entries()].filter(([, v]) => typeof v === "string"));
        if (kind === "complete") {
            const {data: request,error: lookupError}=await db.from("refund_requests").select("status,amount,processed_amount").eq("unit_id",unit).eq("id",id).single();
            if (lookupError||!request) return {error:"Refund not found."};
            if (request.status === "Approved") {
                const amountError=validateRefundIssueAmount(String(form.get("amount")??""),String(request.amount),String(request.processed_amount));
                if (amountError) return {error:amountError};
            }
        }
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

/** Opening a case never approves or issues funds. Read-only staff cannot mutate it. */
export async function openRefundReview(id: string): Promise<RefundState> {
    try {
        const {db, unit} = await requirePermission("payments.refund");
        const {data: request, error} = await db.from("refund_requests")
            .select("status,job_id").eq("unit_id", unit).eq("id", id).single();
        if (error || !request) return {error: error?.message ?? "Refund not found."};
        if (request.status !== "Pending") return {ok: true};
        const result = await refundAction("review", id, {}, new FormData());
        // A concurrent reviewer may already have advanced the case. Never move it backward.
        if (result.error) {
            const {data: latest} = await db.from("refund_requests").select("status")
                .eq("unit_id", unit).eq("id", id).single();
            if (!latest || latest.status === "Pending") return result;
        }
        revalidatePath(`/app/jobs/${request.job_id}`);
        return {ok: true};
    } catch (error) {
        return {error: error instanceof Error ? error.message : "Unable to open refund review."};
    }
}
