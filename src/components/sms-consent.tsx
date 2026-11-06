"use client";
import {HexModalFrame,ModalActions} from "./hex-modal-frame";

import {DialogClose} from "./dialog-close";
import { useActionState, useRef, useEffect } from "react";
import { useRouter } from "next/navigation";
import { saveSmsConsent } from "@/app/sms-actions";
import { SMS_CONSENT_DISCLOSURE, smsPolicyLinks } from "@/lib/domain/sms-consent";
export { SMS_CONSENT_DISCLOSURE } from "@/lib/domain/sms-consent";
export function SmsConsentCheckbox({granted=false}:{granted?:boolean}) {
 const links=smsPolicyLinks();
 return <><label className="checkbox"><input name="sms_opt_in" type="checkbox" defaultChecked={granted} disabled={!links && !granted}/>{SMS_CONSENT_DISCLOSURE}</label>
 <label className="checkbox sms-policy-acceptance"><input name="sms_policy_accepted" type="checkbox" defaultChecked={granted}/>By checking, I accept <a href="/terms" target="_blank" rel="noopener noreferrer">Terms of Service</a> &amp; <a href="/privacy" target="_blank" rel="noopener noreferrer">Privacy Policy</a>.</label>
 {links ? <p><a href={links.privacy} target="_blank" rel="noopener noreferrer">Privacy Policy</a> · <a href={links.terms} target="_blank" rel="noopener noreferrer">Terms</a></p>:<p className="muted">New SMS subscriptions are temporarily unavailable while Privacy Policy and Terms links are configured. Existing subscribers can still opt out.</p>}</>;
}
export function SmsConsentFields({ phone = "", granted = false }: { phone?: string; granted?: boolean }) {
  return <fieldset><legend>Optional SMS updates</legend><label>Mobile number<input name="sms_phone" type="tel" autoComplete="tel" defaultValue={phone} placeholder="+1 (801) …" /></label><SmsConsentCheckbox granted={granted}/></fieldset>;
}
export function SmsPreferences({ token, scope, phone = "", granted = false }: { token: string; scope: "quote" | "status"; phone?: string; granted?: boolean }) {
  const [state, action, pending] = useActionState(saveSmsConsent, {});
  return <details className="panel"><summary>SMS preferences</summary><form action={action} className="stack"><input type="hidden" name="token" value={token} /><input type="hidden" name="scope" value={scope} /><SmsConsentFields phone={phone} granted={granted} /><button disabled={pending}>Save SMS preferences</button>{state.error && <p role="alert" className="notice error">{state.error}</p>}{state.message && <p role="status" className="notice success">{state.message}</p>}</form></details>;
}

export function StatusSmsOptIn({token,phone="",granted=false}:{token:string;phone?:string;granted?:boolean}) {
 const dialog=useRef<HTMLDialogElement>(null);const router=useRouter();
 const [state,action,pending]=useActionState(saveSmsConsent,{});
 useEffect(()=>{if(state.message){dialog.current?.close();router.refresh();}},[state.message,router]);
 if(granted) return <><p className="notice success">SMS notifications are enabled for future updates.</p><SmsPreferences token={token} scope="status" phone={phone} granted /></>;
 return <section className="panel"><button type="button" onClick={()=>dialog.current?.showModal()}>Get Notifications By SMS</button>
 <dialog ref={dialog} className="hex-dialog sms-opt-in-dialog"><HexModalFrame><DialogClose/><form action={action} className="stack"><h2>Get Notifications By SMS</h2><p>Notifications start from your current status. Previous updates will not be sent. Your first SMS will be a welcome message with opt-out instructions.</p><input type="hidden" name="token" value={token}/><input type="hidden" name="scope" value="status"/><SmsConsentFields phone={phone}/><p>Consent is optional and is not a condition of purchase.</p>{state.error&&<p className="notice error" role="alert">{state.error}</p>}<ModalActions><button disabled={pending} name="accept_sms" value="yes">{pending?"Saving…":"I accept"}</button><button type="button" className="secondary" disabled={pending} onClick={()=>dialog.current?.close()}>Cancel</button></ModalActions></form></HexModalFrame></dialog></section>;
}
