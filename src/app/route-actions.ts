"use server";
import {supabase} from "@/lib/supabase/server";
import {context} from "@/lib/domain/context";
import {revalidatePath} from "next/cache";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function routeAvailability(job: string, leg: string, day: string, token?: string) {
 const db = await supabase();
 const result = await db.rpc("route_availability", {p_job:job,p_leg:leg,p_day:day,p_token:token || null});
 return result.error ? {error:result.error.message} : {data:result.data};
}
export async function scheduleRoute(job: string,leg: string,day: string,eta: string,token?: string) {
 if (!token) {const ctx = await context();if(ctx.role !== "admin") return {error:"Admin access required"};}
 const db=await supabase();
 const result=await db.rpc("route_schedule",{p_job:job,p_leg:leg,p_day:day,p_eta:eta,p_token:token || null});
 if(result.error) return {error:result.error.message};
 await dispatchWorkerMail();
 revalidatePath("/pick-return");revalidatePath("/app","layout");
 if(token) revalidatePath(`/status/${token}`);
 return {ok:true};
}
