"use server";
import {z} from "zod";
import {supabase} from "@/lib/supabase/server";
const schema=z.object({token:z.string().regex(/^[a-f0-9]{64}$/i),request:z.string().uuid(),message:z.string().trim().min(1).max(10000)});
export async function submitStatusSupport(token:string,request:string,message:string):Promise<{error?:string;reference?:string}>{
 const parsed=schema.safeParse({token,request,message});if(!parsed.success)return {error:"Enter your inquiry (up to 10,000 characters)."};
 try{const db=await supabase();const {data,error}=await db.rpc("submit_status_support",{p_token:token,p_request:request,p_message:parsed.data.message});return error?{error:error.message}:{reference:data as string};}
 catch{return {error:"We could not submit your inquiry. Please try again."};}
}
