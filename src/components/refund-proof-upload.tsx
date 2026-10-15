"use client";
import {useState} from "react";
import {EvidenceUpload} from "./evidence-upload";
export function RefundProofUpload({job,id,method}:{job:string;id:string;method?:string|null}){
 const [selected,setSelected]=useState(method||"Zelle");return <><label>Proof payment method<select value={selected} onChange={e=>setSelected(e.target.value)}>{["Zelle","Venmo","Card","Bank Transfer","Check"].map(m=><option key={m}>{m}</option>)}</select></label><EvidenceUpload key={selected} accept="image/png,image/jpeg,image/webp" config={{jobId:job,refundRequestId:id,refundMethod:selected,type:"Refund Review Evidence",defaultVisibility:"internal",back:"/app/finance/refunds"}}/><small>Upload a screenshot of this manual refund. It must match the issuance method.</small></>;
}
