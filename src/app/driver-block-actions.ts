"use server";
import {requirePermission} from "@/lib/domain/context";
import {revalidatePath} from "next/cache";
export async function acceptDriverBlock(route:string,key:string,insurance:string,registration:string){
 const {db}=await requirePermission("driver.routes","pr.routes.live");
 const result=await db.rpc("accept_driver_block",{p_route:route,p_key:key,p_insurance_until:insurance,p_registration_until:registration});
 if(result.error)return {error:result.error.message};
 revalidatePath("/pick-return","layout");return {ok:true};
}
