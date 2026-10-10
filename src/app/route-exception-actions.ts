"use server";
import {context} from "@/lib/domain/context";
import {supabase} from "@/lib/supabase/server";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
import {revalidatePath} from "next/cache";
export async function driverIncidentAction(id:string,outcome?:string){
 const {db}=await context();const result=outcome?await db.rpc('resolve_driver_incident',{p_incident:id,p_outcome:outcome}):await db.rpc('report_driver_incident',{p_route:id});
 if(result.error)return {error:result.error.message};await dispatchWorkerMail();revalidatePath('/pick-return','layout');revalidatePath('/app/refunds');return {ok:true};
}
export async function driverIncidentChoice(job:string,token:string,choice:string){
 const db=await supabase();const result=await db.rpc('driver_incident_choice',{p_job:job,p_token:token,p_choice:choice});if(result.error)return {error:result.error.message};await dispatchWorkerMail();revalidatePath(`/status/${token}`);revalidatePath('/pick-return','layout');return {ok:true};
}
export async function confirmRouteRefund(id:string,reference:string){
 const {db}=await context();const result=await db.rpc('confirm_route_refund',{p_id:id,p_reference:reference});if(result.error)return {error:result.error.message};await dispatchWorkerMail();revalidatePath('/app/refunds');return {ok:true};
}
