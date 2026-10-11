import { createClient } from "@supabase/supabase-js";
export async function stripeTestCustomer(jobId:string) {
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SECRET_KEY??process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!url||!key)return false;
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:job,error}=await db.from("jobs").select("flow_id").eq("id",jobId).single();if(error||!job)return false;
 const {data:flow}=await db.from("commercial_flows").select("customer_id").eq("id",job.flow_id).single();if(!flow)return false;
 const {data:customer}=await db.from("customers").select("name").eq("id",flow.customer_id).single();
 return typeof customer?.name==="string" && customer.name.startsWith("TEST-");
}
