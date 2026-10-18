"use client";
import {ModalClose} from "./modal-close";
import {DialogClose} from "./dialog-close";
import {createContext,useEffect,useRef,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {supportClosureProtocol} from "@/app/support-actions";
export const SupportClosureContext=createContext<{open:()=>void;pending:boolean;closed:boolean;label:string}|null>(null);
export function SupportCaseModal({children,id,section,name,reference,job,returnTo,closed}:{children:React.ReactNode;id:string;section:string;name:string;reference:string;job:string;closed:boolean;returnTo?:string}){
 const prompt=useRef<HTMLDialogElement>(null);
 const dialog=useRef<HTMLDialogElement>(null),request=useRef<{id:string;completed:boolean}|null>(null),router=useRouter();const [confirm,setConfirm]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState(""),[pending,start]=useTransition();
 useEffect(()=>{dialog.current?.showModal();},[]);
 useEffect(()=>{if(confirm)prompt.current?.showModal();else prompt.current?.close();},[confirm]);
 const protocol=(completed:boolean)=>start(async()=>{if(!request.current||request.current.completed!==completed)request.current={id:crypto.randomUUID(),completed};const result=await supportClosureProtocol(id,request.current.id,completed);if(result.error){setError(result.error);return;}request.current=null;setConfirm(false);if(completed){router.push(`/app/support?section=${section}&tab=resolved`);}else{setNotice("Follow-up question sent. Wait for the customer's answer, then confirm that no further help is needed before closing.");}router.refresh();});
 return <dialog ref={dialog} className="support-case-modal" onCancel={()=>router.push(returnTo??`/app/support?section=${section}`)}><header className="support-case-header"><div><h2>{name}</h2><p>{reference}</p><strong>{job||"No linked Job"}</strong></div><div className="actions"><ModalClose className="secondary modal-close" aria-label="Dismiss case details" disabled={pending} onClick={()=>{dialog.current?.close();router.push(returnTo??`/app/support?section=${section}`);}}>×</ModalClose></div></header>
 {notice&&<p role="status">{notice}</p>}{error&&<p className="notice error" role="alert">{error}</p>}<SupportClosureContext.Provider value={{open:()=>setConfirm(true),pending,closed,label:section==="questions"?"End Inquiry":"Close case"}}>{children}</SupportClosureContext.Provider>
 <dialog ref={prompt} className="support-close-confirm" onCancel={()=>setConfirm(false)} aria-label="Closure protocol"><DialogClose/><h3>Was the closure protocol followed?</h3><p>Confirm that you asked whether we could help with anything else and the customer said no. Yes sends the final courtesy message and resolves the case. No sends the follow-up question.</p><div className="actions"><button disabled={pending} onClick={()=>protocol(true)}>Yes</button><button className="secondary" disabled={pending} onClick={()=>protocol(false)}>No</button><button className="secondary" disabled={pending} onClick={()=>setConfirm(false)}>Go back</button></div></dialog></dialog>;
}
