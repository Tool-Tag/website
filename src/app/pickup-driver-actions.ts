"use server";
import {refreshStopRouteEstimates} from "@/lib/integrations/route-estimate";
import type {Point} from "@/lib/domain/route-estimate";
import {requirePermission} from "@/lib/domain/context";
import {supabase} from "@/lib/supabase/server";
import {revalidatePath} from "next/cache";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function pickupDriverAction(stop:string,action:string,position?:Point|null){
 const {db}=await requirePermission("driver.routes","pr.routes.live");const r=await db.rpc("pickup_driver_action",{p_stop:stop,p_action:action});
 if(r.error)return {error:r.error.message};
 if(["picked-up","delivered"].includes(action)){try{await refreshStopRouteEstimates(db,stop,position);}catch{/* The completed stop remains committed; the nearby notice still sends without a fabricated ETA. */}}
 await dispatchWorkerMail();revalidatePath("/pick-return","layout");return {ok:true};
}
export async function pickupMissChoice(job:string,token:string,choice:string){
 const db=await supabase();const r=await db.rpc("pickup_miss_choice",{p_job:job,p_token:token,p_choice:choice});
 if(r.error)return {error:r.error.message};
 await dispatchWorkerMail();revalidatePath(`/status/${token}`);revalidatePath("/pick-return","layout");return {ok:true};
}

export async function choosePickupRetryDay(job:string,token:string,day:string){
 const db=await supabase();const {error}=await db.rpc("choose_pickup_retry_day",{p_job:job,p_token:token,p_day:day});if(error)return {error:error.message};
 await dispatchWorkerMail();revalidatePath(`/status/${token}`);revalidatePath("/app/pick-return");return {ok:true};
}
