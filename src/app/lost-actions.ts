"use server";
import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/domain/context";
import { supabase } from "@/lib/supabase/server";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
import type {LostChoice} from "@/lib/domain/lost-flow";

export async function lostStaffAction(id:string,action:"notify"|"approve"|"finalize"|"confirm-replacement",fields:{market_value?:string;notes?:string}={}) {
 try {
  const {db}=await requirePermission("jobs.manage","pr.returns");
  const {error}=await db.rpc("lost_staff_action",{p:{id,action,market_value:fields.market_value,notes:fields.notes}});
  if(error)return {error:error.message};
  revalidatePath("/app","layout");
  if(action==="notify"||action==="approve"||action==="finalize")await dispatchWorkerMail();
  return {ok:true};
 }catch(error){return {error:error instanceof Error?error.message:"Unable to update Lost case."};}
}
export async function lostCustomerChoice(token:string,choice:LostChoice) {
 try {
  if(!/^[a-f0-9]{64}$/.test(token)||!["Replace Item","Refund money"].includes(choice))return {error:"Invalid response."};
  const db=await supabase();
  const {error}=await db.rpc("public_lost_resolution",{p_token:token,p_choice:choice});
  if(error)return {error:error.message};
  revalidatePath(`/lost/${token}`);revalidatePath("/app/lost");
  return {ok:true};
 }catch{return {error:"Unable to save your choice. Please try again."};}
}

export async function lostPaymentDetails(token:string,details:import("@/lib/security/lost-payment-details").LostPaymentDetails){
 try{
  if(!/^[a-f0-9]{64}$/.test(token))return {error:"Invalid link."};
  const db=await supabase();const {data,error}=await db.rpc("public_lost_resolution",{p_token:token,p_choice:null});
  if(error||!data?.lost_id)return {error:"Resolution link unavailable."};
  const {validateLostPaymentDetails,encryptLostPaymentDetails}=await import("@/lib/security/lost-payment-details");
  const clean=validateLostPaymentDetails(details,data.original_method);
  const encrypted=encryptLostPaymentDetails(clean,data.lost_id);
  const {storageAdmin}=await import("@/lib/storage/admin");
  const result=await storageAdmin().rpc("submit_lost_payment_details",{p_token:token,p_method:clean.method,p_encrypted:encrypted});
  if(result.error)return {error:result.error.message};
  revalidatePath(`/lost/${token}`);revalidatePath("/app","layout");return {ok:true};
 }catch(error){return {error:error instanceof Error?error.message:"Unable to submit payment details."};}
}
export async function lostFulfillmentChoice(token:string,choice:string,address:string){
 try{
  if(!/^[a-f0-9]{64}$/.test(token))return {error:"Invalid link."};
  const db=await supabase();const {error}=await db.rpc("choose_lost_replacement_fulfillment",{p_token:token,p_choice:choice,p_address:address});
  if(error)return {error:error.message};revalidatePath(`/lost/${token}`);revalidatePath("/app","layout");return {ok:true};
 }catch{return {error:"Unable to save your choice."};}
}
export async function scheduleLostReplacement(id:string){
 try{const {db}=await requirePermission("pr.routes.plan");const {data,error}=await db.rpc("schedule_lost_replacement",{p_delivery:id});if(error)return {error:error.message};if(!data)return {error:"No block is currently available. Your priority request remains queued."};revalidatePath("/app/pick-return");return {ok:true};}catch{return {error:"Unable to assign replacement delivery."};}
}
