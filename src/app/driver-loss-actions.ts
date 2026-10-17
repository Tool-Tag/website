"use server";
import {requirePermission} from "@/lib/domain/context";
import {revalidatePath} from "next/cache";
export async function acceptDriverLossAgreement(id:string){
 try{const {db}=await requirePermission("driver.routes","pr.routes.live","pr.routes.plan");const {error}=await db.rpc("driver_loss_agreement",{p_id:id,p_accept:true});if(error)return {error:error.message};revalidatePath("/pick-return","layout");revalidatePath("/app/lost");return {ok:true};}catch{return {error:"Unable to record driver acceptance."};}
}
export async function driverLossOwnerDecision(driver:string,action:"allow"|"ban",reason:string){
 try{const {db,access}=await requirePermission("users.manage");if(!access.owner)return {error:"Only Owner can decide driver eligibility."};const {error}=await db.rpc("driver_loss_owner_decision",{p_driver:driver,p_action:action,p_reason:reason});if(error)return {error:error.message};revalidatePath("/app","layout");revalidatePath("/pick-return","layout");return {ok:true};}catch{return {error:"Unable to record Owner decision."};}
}
