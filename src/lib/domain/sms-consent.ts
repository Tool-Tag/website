export const SMS_CONSENT_DISCLOSURE = "I agree to receive automated transactional SMS from ToolTag about this quote/job, scheduling, driver arrival, confirmations and payments at the number provided. Consent is optional and is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out, HELP for help, or manage preferences in tracking.";
export function smsPolicyLinks(env: Record<string,string|undefined> = {privacy:process.env.NEXT_PUBLIC_TOOLTAG_PRIVACY_URL,terms:process.env.NEXT_PUBLIC_TOOLTAG_TERMS_URL}) {
 const valid=(s:string|undefined)=>{if(!s)return false;try{const u=new URL(s);return u.protocol==="https:" && !u.username && !u.password;}catch{return false;}};
 return valid(env.privacy) && valid(env.terms) ? {privacy:env.privacy!,terms:env.terms!}:null;
}
