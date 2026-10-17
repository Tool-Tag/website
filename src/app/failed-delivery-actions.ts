"use server";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
import { requirePermission } from "@/lib/domain/context";
import { revalidatePath } from "next/cache";
export async function verifyFailedDelivery(stop: string, items: string[]) {
 const { db } = await requirePermission("pr.returns");
 const { error } = await db.rpc("verify_failed_delivery", {p_stop:stop,p_items:items});
 if (error) return {error:error.message};
 revalidatePath("/app", "layout");return {ok:true};
}
export async function markFailedDeliveryLost(stop:string,checked:string[],explanation:string,marketValue:string) {
 const {db}=await requirePermission("pr.returns");
 const {error}=await db.rpc("mark_failed_delivery_lost_v2", {p_stop:stop,p_checked:checked,p_explanation:explanation,p_market_value:marketValue});
 if(error)return {error:error.message};
 await dispatchWorkerMail();
 revalidatePath("/app","layout");revalidatePath("/pick-return","layout");return {ok:true};
}
