"use server";
import { requirePermission } from "@/lib/domain/context";
import { revalidatePath } from "next/cache";
export async function verifyFailedDelivery(stop: string, items: string[]) {
 const { db } = await requirePermission("pr.returns");
 const { error } = await db.rpc("verify_failed_delivery", {p_stop:stop,p_items:items});
 if (error) return {error:error.message};
 revalidatePath("/app", "layout");return {ok:true};
}
export async function markFailedDeliveryLost(stop:string,checked:string[],explanation:string) {
 const {db}=await requirePermission("pr.returns");
 const {error}=await db.rpc("mark_failed_delivery_lost", {p_stop:stop,p_checked:checked,p_explanation:explanation});
 if(error)return {error:error.message};
 revalidatePath("/app","layout");revalidatePath("/pick-return","layout");return {ok:true};
}
