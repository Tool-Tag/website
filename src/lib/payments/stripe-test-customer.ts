import { createClient } from "@supabase/supabase-js";
export async function stripeTestCustomer(jobId:string) {
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SECRET_KEY??process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!key)return false;
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data,error}=await db.rpc("stripe_test_customer",{p_job:jobId});
 return !error && data===true;
}
