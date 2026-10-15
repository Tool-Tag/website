"use client";
import {useRef, useState, useTransition} from "react";
import {useRouter} from "next/navigation";
import {openRefundReview} from "@/app/refund-actions";

export function RefundCaseModal({id,title,status,reason,requested,canReview,children}:{id:string;title:string;status:string;reason:string;requested:string;canReview:boolean;children:React.ReactNode}) {
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
  <button type="button" className="secondary" style={{width:"100%",textAlign:"left",padding:"1rem"}} onClick={open} aria-haspopup="dialog">
   <strong>{title}</strong><br/>{status} · {reason}<br/><small>Requested: {requested}</small>
  </button>
  <dialog ref={dialog} className="support-case-modal" aria-label={`Refund details: ${title}`} style={{width:"min(48rem, calc(100vw - 2rem))",maxHeight:"85dvh",overflowY:"auto"}}>
   <header className="actions" style={{justifyContent:"space-between"}}><h2>Refund details</h2><button type="button" className="secondary" onClick={()=>dialog.current?.close()}>Close</button></header>
   {pending&&<p role="status">Opening review…</p>}
   {error&&<p className="notice error" role="alert">{error} Close and reopen to retry.</p>}
   {!canReview&&status==="Pending"&&<p>Read-only access. An authorized staff member must review this refund.</p>}
   {children}
  </dialog>
 </>;
}
