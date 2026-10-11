"use client";
import { useEffect, useState } from "react";
export function PhoneVerification({phone}:{phone:string}) {
 const [enabled,setEnabled]=useState(false),[consent,setConsent]=useState(false),[code,setCode]=useState(""),[sentTo,setSentTo]=useState(""),[verifiedTo,setVerifiedTo]=useState(""),[pending,setPending]=useState(false),[message,setMessage]=useState("");
 useEffect(()=>{let active=true;fetch("/api/phone-verification",{cache:"no-store"}).then(r=>r.json()).then(j=>{if(active)setEnabled(j.enabled===true);}).catch(()=>{});return()=>{active=false;};},[]);
 if(!enabled)return null;
 const verified=verifiedTo===phone && phone!=="",sent=sentTo===phone && phone!=="";
 async function act(action:"send"|"verify") {
  setPending(true);setMessage("");
  try {const r=await fetch("/api/phone-verification",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action,phone,consent,code})});const j=await r.json();if(!r.ok)throw new Error(j.error??"Unable to verify your phone.");
   if(action==="send"){setSentTo(phone);setVerifiedTo("");setCode("");setMessage("Code sent. It expires in 10 minutes.");}else{setVerifiedTo(phone);setMessage("Phone verified. Complete registration within 10 minutes.");}
  }catch(e){setMessage(e instanceof Error?e.message:"Unable to verify your phone.");}finally{setPending(false);}
 }
 return <fieldset className="wide"><legend>Verify your phone</legend><p>Verify this number before completing registration. This does not subscribe you to future SMS alerts.</p><label><input type="checkbox" checked={consent} onChange={e=>setConsent(e.target.checked)}/> I agree to receive a one-time SMS verification code at this number. Message and data rates may apply.</label><button type="button" disabled={pending||!consent||!phone||verified} onClick={()=>act("send")}>{sent?"Resend code":"Send verification code"}</button>{sent&&!verified&&<><label>Six-digit code<input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} onChange={e=>setCode(e.target.value.replace(/\D/g,""))}/></label><button type="button" disabled={pending||code.length!==6} onClick={()=>act("verify")}>Verify code</button></>}{message&&<p role="status">{message}</p>}</fieldset>;
}
