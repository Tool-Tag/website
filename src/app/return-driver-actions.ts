"use server";
import {refreshStopRouteEstimates} from "@/lib/integrations/route-estimate";
import type {Point} from "@/lib/domain/route-estimate";
import {context} from "@/lib/domain/context";
import {supabase} from "@/lib/supabase/server";
import {revalidatePath} from "next/cache";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function returnDriverAction(stop:string,action:string,present=false,position?:Point|null){
 const {db}=await context();const r=await db.rpc("return_driver_action",{p_stop:stop,p_action:action,p_present:present});
 if(r.error)return {error:r.error.message};if(["picked-up","delivered"].includes(action)){try{await refreshStopRouteEstimates(db,stop,position);}catch{/* The completed stop remains committed; the nearby notice still sends without a fabricated ETA. */}}
 await dispatchWorkerMail();revalidatePath("/pick-return","layout");return {ok:true};
}
export async function acknowledgeReturn(token:string){
 const db=await supabase();const r=await db.rpc("public_completion",{p_token:token,p_decision:"accept"});
 if(r.error)return {error:r.error.message};await dispatchWorkerMail();revalidatePath("/pick-return","layout");revalidatePath(`/completion/${token}`);return {ok:true};
}
