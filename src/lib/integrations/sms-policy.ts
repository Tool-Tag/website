import type { SupabaseClient } from "@supabase/supabase-js";
import { smsPolicyLinks } from "@/lib/domain/sms-consent";
export async function smsGrantAllowed(db:SupabaseClient,token:string,scope:string,phone:string,granted:boolean) {
 if(!granted || smsPolicyLinks())return true;
 // Missing links must not silently revoke an existing subscription or block accepting a quote.
 // New numbers/subscriptions remain disabled until approved links are configured.
 const prior=await db.rpc("sms_consent_state",{p_token:token,p_scope:scope});
 return !prior.error && prior.data?.granted===true && prior.data.phone===phone;
}
