"use client";
import {DialogClose} from "./dialog-close";
import {useRef,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {createSupportCase} from "@/app/support-actions";
export type SupportDirectory={customers:{id:string;name:string;email:string}[];jobs:{id:string;code:string;customer_id:string}[]};
export function NewSupportCase({directory}:{directory:SupportDirectory}){
 const dialog=useRef<HTMLDialogElement>(null),request=useRef<string|null>(null),router=useRouter();const [customer,setCustomer]=useState("");const [error,setError]=useState("");const [pending,start]=useTransition();
 return <><button className="menu-link-blue-electric" onClick={()=>dialog.current?.showModal()}>New case</button><dialog ref={dialog} className="login-attention"><DialogClose/><h2>New case · Phone call</h2><form className="stack" onSubmit={e=>{e.preventDefault();const form=new FormData(e.currentTarget);start(async()=>{request.current ||=crypto.randomUUID();const result=await createSupportCase(request.current,customer,String(form.get("job")||""),String(form.get("subject")||""),String(form.get("body")||""));if(result.error){setError(result.error);return;}dialog.current?.close();request.current=null;router.push(`/app/support?id=${result.id}`);router.refresh();});}}>
 <label>Customer<select value={customer} onChange={e=>setCustomer(e.target.value)} required disabled={pending}><option value="">Select customer…</option>{directory.customers.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
 <label>Job · optional<select name="job" key={customer} disabled={pending}><option value="">No linked Job</option>{directory.jobs.filter(j=>j.customer_id===customer).map(j=><option key={j.id} value={j.id}>{j.code}</option>)}</select></label>
 <label>Subject<input name="subject" required maxLength={500} disabled={pending}/></label><label>Call details<textarea name="body" required maxLength={20000} rows={5} disabled={pending}/></label>{error&&<p role="alert">{error}</p>}<div className="actions"><button disabled={pending}>Create case</button><button type="button" className="secondary" disabled={pending} onClick={()=>dialog.current?.close()}>Cancel</button></div></form></dialog></>;
}
