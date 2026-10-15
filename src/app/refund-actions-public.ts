"use server";
import {supabase} from "@/lib/supabase/server";
import {revalidatePath} from "next/cache";
export async function acknowledgeRefund(token:string){
 if(!/^[a-f0-9]{64}$/.test(token))return {error:"Refund link unavailable."};
 const db=await supabase();const {error}=await db.rpc("public_refund",{p_token:token,p_ack:true});if(error)return {error:"Could not confirm receipt. Please try again."};revalidatePath(`/refund/${token}`);return {ok:true};
}
