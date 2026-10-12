export const SMS_CONSENT_DISCLOSURE = "By checking, you consent to receive delivery updates and shipping notifications from ToolTag, a DBA of Bandits of the Framing LLC. Message frequency may vary. Message and data rates may apply. Reply HELP for help or STOP to opt-out.";
export const SMS_POLICY_ACCEPTANCE = "By checking, I accept Terms of Service & Privacy Policy.";
export function smsPolicyLinks(env: Record<string,string|undefined> = {privacy:process.env.NEXT_PUBLIC_TOOLTAG_PRIVACY_URL || "https://tooltag.martinlab.studio/privacy",terms:process.env.NEXT_PUBLIC_TOOLTAG_TERMS_URL || "https://tooltag.martinlab.studio/terms"}) {
 const valid=(s:string|undefined)=>{if(!s)return false;try{const u=new URL(s);return u.protocol==="https:" && !u.username && !u.password;}catch{return false;}};
 return valid(env.privacy) && valid(env.terms) ? {privacy:env.privacy!,terms:env.terms!}:null;
}
