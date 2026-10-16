"use client";
import {useRef, useState, useTransition} from "react";
import {useRouter} from "next/navigation";
import {useRefundTab} from "./refund-status-tabs";
import {Badge} from "@/components/ui";
import type {Urgency} from "@/lib/domain/urgent-attention";
import {openRefundReview} from "@/app/refund-actions";

export function RefundCaseModal({id,title,customer,status,reason,requested,days,color,canReview,children}:{id:string;title:string;customer:string;status:string;reason:string;requested:string;days:number;color:Urgency;canReview:boolean;children:React.ReactNode}) {
 const selectedTab=useRefundTab();
 const dialog=useRef<HTMLDialogElement>(null);
 const router=useRouter();
 const [error,setError]=useState("");
 const [pending,start]=useTransition();
 function open() {
  dialog.current?.showModal();
  setError("");
  if(canReview && status==="Pending") start(async()=>{
   const result=await openRefundReview(id);
   if(result.error) setError(result.error);
   router.refresh();
  });
 }
 return <>
  {(selectedTab===null||selectedTab===status)&&<button type="button" className="secondary" style={{width:"100%",textAlign:"left",padding:"1rem"}} onClick={open} aria-haspopup="dialog">
   <span className={`support-urgency-dot dot-${color}`} aria-label={`${color} urgency`}/><strong>{customer} · {title}</strong><br/>{status} · {reason}<br/><small>{days} business {days===1?"day":"days"} waiting{days===0?" — awaiting eligibility confirmation":""} · Requested: {requested}</small>
  </button>}
  <dialog ref={dialog} className="support-case-modal" aria-label={`Refund details: ${title}`} style={{width:"min(48rem, calc(100vw - 2rem))",maxHeight:"85dvh",overflowY:"auto"}}>
   <header className="actions" style={{justifyContent:"space-between"}}><div><h2>{customer}</h2><p>{title}</p><Badge>{status}</Badge><p><span className={`support-urgency-dot dot-${color}`} aria-label={`${color} urgency`}/>{days} business {days===1?"day":"days"} waiting{days===0?" — awaiting eligibility confirmation":""}</p></div><button type="button" className="secondary" onClick={()=>dialog.current?.close()}>Close</button></header>
   {pending&&<p role="status">Opening review…</p>}
   {error&&<p className="notice error" role="alert">{error} Close and reopen to retry.</p>}
   {!canReview&&status==="Pending"&&<p>Read-only access. An authorized staff member must review this refund.</p>}
   {children}
  </dialog>
 </>;
}
