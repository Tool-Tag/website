"use client";
import {useEffect,useRef} from "react";
import {useRouter} from "next/navigation";
export function SupportCaseModal({children,section,name,reference,job,returnTo}:{children:React.ReactNode;section:string;name:string;reference:string;job:string;returnTo?:string}){
 const dialog=useRef<HTMLDialogElement>(null),router=useRouter();
 const dismiss=()=>{dialog.current?.close();router.push(returnTo??`/app/support?section=${section}`);};
 useEffect(()=>{dialog.current?.showModal();},[]);
 return <dialog ref={dialog} className="support-case-modal" onCancel={()=>router.push(returnTo??`/app/support?section=${section}`)}><header className="support-case-header"><div><h2>{name}</h2><p>{reference}</p><strong>{job||"No linked Job"}</strong></div><button type="button" className="secondary modal-close" aria-label="Dismiss case details" onClick={dismiss}>×</button></header>
 {children}
 </dialog>;
}
