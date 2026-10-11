"use server";
import {context} from "@/lib/domain/context";
import {supabase} from "@/lib/supabase/server";
import {revalidatePath} from "next/cache";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function customerRouteResponse(token:string,leg:"Pickup"|"Return") {
 const db=await supabase();const {error}=await db.rpc("customer_arrival_response",{p_token:token,p_leg:leg});
 if(error)return {error:error.message};revalidatePath(`/status/${token}`);return {ok:true};
}
export async function customerDeliveryAcknowledge(token:string) {
 const db=await supabase();const {error}=await db.rpc("customer_delivery_acknowledge",{p_token:token});
 if(error)return {error:error.message};await dispatchWorkerMail().catch(()=>console.error("DELIVERY_ACK_NOTIFICATION_DISPATCH_FAILED"));revalidatePath(`/status/${token}`);return {ok:true};
}
export async function verifyShopItem(item:string){
 const {db}=await context();const {error}=await db.rpc("verify_shop_item",{p_item:item});
 if(error)return {error:error.message};revalidatePath("/app","layout");revalidatePath("/pick-return","layout");revalidatePath("/app/pick-return");return {ok:true};
}
export async function getRouteChecklist(route:string,kind:"Loaded"|"Returned"){
 const {db}=await context();const {data,error}=await db.rpc("route_item_checklist",{p_route:route,p_kind:kind});
 if(error)return {error:error.message};return {data};
}
export async function verifyRouteItems(stop:string,kind:"Loaded"|"Returned",items:string[]){
 const {db}=await context();const {error}=await db.rpc("verify_route_items",{p_stop:stop,p_kind:kind,p_items:items});
 if(error)return {error:error.message};revalidatePath("/pick-return","layout");revalidatePath("/app/pick-return");return {ok:true};
}
