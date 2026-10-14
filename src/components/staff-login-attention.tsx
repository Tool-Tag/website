import type {SupabaseClient} from "@supabase/supabase-js";
import {LoginAttention} from "./login-attention";
import {aggregateBands,classifyAttention,type AttentionRecord} from "@/lib/domain/urgent-attention";
export async function StaffLoginAttention({db,sessionId}:{db:SupabaseClient;sessionId:string}){
 const {data,error}=await db.rpc("urgent_login_attention");
 if(error)throw new Error("Could not load pending login attention.");
 if(!data?.eligible)return null;
 return <LoginAttention sessionId={sessionId} bands={aggregateBands(classifyAttention((data.items??[]) as AttentionRecord[]))}/>;
}
