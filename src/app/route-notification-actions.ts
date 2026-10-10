"use server";
import {refreshRouteEstimates} from "@/lib/integrations/route-estimate";
import {context} from "@/lib/domain/context";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
import {revalidatePath} from "next/cache";
export async function departDriverRoute(route:string){
 const {db}=await context();
 const result=await db.rpc("depart_driver_route",{p_route:route});
 if(result.error)return {error:result.error.message};
 await dispatchWorkerMail();revalidatePath("/pick-return","layout");return {ok:true};
}

export async function updateRouteLocation(route:string,point:{latitude:number;longitude:number}){
 const {db}=await context();
 try{await refreshRouteEstimates(db,route,point);await dispatchWorkerMail();revalidatePath("/pick-return","layout");return {ok:true};}
 catch{return {error:"Could not update ETA aprox. Try again."};}
}
