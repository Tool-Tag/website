"use client";
import { useActionState } from "react";
import { saveSmsConsent } from "@/app/sms-actions";
import { SMS_CONSENT_DISCLOSURE, smsPolicyLinks } from "@/lib/domain/sms-consent";
export { SMS_CONSENT_DISCLOSURE } from "@/lib/domain/sms-consent";
export function SmsConsentCheckbox({granted=false}:{granted?:boolean}) {
 const links=smsPolicyLinks();
 return <><label className="checkbox"><input name="sms_opt_in" type="checkbox" defaultChecked={granted} disabled={!links && !granted}/>{SMS_CONSENT_DISCLOSURE}</label>
 {links ? <p><a href={links.privacy} target="_blank" rel="noopener noreferrer">Privacy Policy</a> · <a href={links.terms} target="_blank" rel="noopener noreferrer">Terms</a></p>:<p className="muted">New SMS subscriptions are temporarily unavailable while Privacy Policy and Terms links are configured. Existing subscribers can still opt out.</p>}</>;
}
export function SmsConsentFields({ phone = "", granted = false }: { phone?: string; granted?: boolean }) {
  return <fieldset><legend>Optional SMS updates</legend><label>Mobile number<input name="sms_phone" type="tel" autoComplete="tel" defaultValue={phone} placeholder="+1 (801) …" /></label><SmsConsentCheckbox granted={granted}/></fieldset>;
}
export function SmsPreferences({ token, scope, phone = "", granted = false }: { token: string; scope: "quote" | "status"; phone?: string; granted?: boolean }) {
  const [state, action, pending] = useActionState(saveSmsConsent, {});
  return <details className="panel"><summary>SMS preferences</summary><form action={action} className="stack"><input type="hidden" name="token" value={token} /><input type="hidden" name="scope" value={scope} /><SmsConsentFields phone={phone} granted={granted} /><button disabled={pending}>Save SMS preferences</button>{state.error && <p role="alert" className="notice error">{state.error}</p>}{state.message && <p role="status" className="notice success">{state.message}</p>}</form></details>;
}
