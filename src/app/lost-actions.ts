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
  if(action==="notify"||action==="approve")await dispatchWorkerMail();
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
