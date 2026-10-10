"use server";
import {context} from "@/lib/domain/context";
import {supabase} from "@/lib/supabase/server";
import {revalidatePath} from "next/cache";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function pickupDriverAction(stop:string,action:string){
 const {db}=await context();const r=await db.rpc("pickup_driver_action",{p_stop:stop,p_action:action});
 if(r.error)return {error:r.error.message};
 await dispatchWorkerMail();revalidatePath("/pick-return","layout");return {ok:true};
}
export async function pickupMissChoice(job:string,token:string,choice:string){
 const db=await supabase();const r=await db.rpc("pickup_miss_choice",{p_job:job,p_token:token,p_choice:choice});
 if(r.error)return {error:r.error.message};
 await dispatchWorkerMail();revalidatePath(`/status/${token}`);revalidatePath("/pick-return","layout");return {ok:true};
}
