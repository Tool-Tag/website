"use client";
import {ModalActions} from "./hex-modal-frame";
import { useContext, useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { closeSupportCase, markSupportRead, replySupport } from "@/app/support-actions";
import { SupportClosureContext } from "./support-case-modal";
export function SupportConversation({id,through,closed,canClose,sendEnabled}:{id:string;through:string;closed:boolean;canClose:boolean;sendEnabled:boolean}) {
 const closure=useContext(SupportClosureContext);
 const router=useRouter(),[body,setBody]=useState(""),[error,setError]=useState(""),[pending,start]=useTransition(),request=useRef<string|null>(null);
 useEffect(()=>{void markSupportRead(id,through);},[id,through]);
 return <div className="support-reply"><form onSubmit={e=>{e.preventDefault();if(pending||!sendEnabled||!body.trim())return;start(async()=>{request.current ||= crypto.randomUUID();const result=await replySupport(id,request.current,body);if(result.error){setError(result.error);if("retryable" in result && result.retryable)request.current=null;}else{setBody("");setError("");request.current=null;}router.refresh();});}}>
 <label htmlFor="support-reply">Reply · your name is added automatically</label><textarea id="support-reply" value={body} onChange={e=>setBody(e.target.value)} maxLength={20000} rows={6} required disabled={pending} aria-describedby={!sendEnabled?"support-reply-status":undefined}/>
 {!sendEnabled && <p id="support-reply-status" className="muted">You can write a reply, but Gmail sending is not enabled in this environment. Your reply has not been sent.</p>}
 {error && <p className="notice error" role="alert">{error}</p>}
 <ModalActions className="actions support-reply-actions"><button disabled={pending || closure?.pending || !sendEnabled || !body.trim()}>{pending ? "Working…":"Send reply"}</button>
 {canClose && !closed && <button type="button" className="secondary" disabled={pending} onClick={()=>start(async()=>{const result=await closeSupportCase(id);setError(result.error || "");router.refresh();})}>Mark resolved</button>}
 {closure && !closure.closed && <button type="button" className="danger support-end-inquiry" disabled={pending || closure.pending} onClick={closure.open}>{closure.label}</button>}</ModalActions>
 </form></div>;
}
