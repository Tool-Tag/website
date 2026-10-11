"use client";
import { useActionState } from "react";
import { saveSmsConsent } from "@/app/sms-actions";
export const SMS_CONSENT_DISCLOSURE = "I agree to receive automated transactional SMS from ToolTag about this quote/job, scheduling, driver arrival, confirmations and payments at the number provided. Consent is optional and is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out, HELP for help, or manage preferences in tracking.";
export function SmsConsentFields({ phone = "", granted = false }: { phone?: string; granted?: boolean }) {
  return <fieldset><legend>Optional SMS updates</legend><label>Mobile number<input name="sms_phone" type="tel" autoComplete="tel" defaultValue={phone} placeholder="+1 (801) …" /></label><label className="checkbox"><input name="sms_opt_in" type="checkbox" defaultChecked={granted} />{SMS_CONSENT_DISCLOSURE}</label></fieldset>;
}
export function SmsPreferences({ token, scope, phone = "", granted = false }: { token: string; scope: "quote" | "status"; phone?: string; granted?: boolean }) {
  const [state, action, pending] = useActionState(saveSmsConsent, {});
  return <details className="panel"><summary>SMS preferences</summary><form action={action} className="stack"><input type="hidden" name="token" value={token} /><input type="hidden" name="scope" value={scope} /><SmsConsentFields phone={phone} granted={granted} /><button disabled={pending}>Save SMS preferences</button>{state.error && <p role="alert" className="notice error">{state.error}</p>}{state.message && <p role="status" className="notice success">{state.message}</p>}</form></details>;
}
