"use client";
import {createContext,useContext,useId,useRef,useState,type ReactNode} from "react";
import {useRouter} from "next/navigation";
import {DialogClose} from "./dialog-close";
const SavedContext=createContext<(()=>void)|null>(null);
export const useActionModal=()=>useContext(SavedContext);
export function ActionModal({title,label,children}:{title:string;label:string;children:ReactNode}) {
 const ref=useRef<HTMLDialogElement>(null),id=useId(),router=useRouter(),[open,setOpen]=useState(false);
 return <><button type="button" className="menu-link-blue-electric" onClick={()=>{setOpen(true);ref.current?.showModal();}}>{label}</button>
 <dialog ref={ref} className="action-modal" aria-labelledby={id} onClose={()=>setOpen(false)}><DialogClose/><h2 id={id}>{title}</h2>
 {open&&<SavedContext.Provider value={()=>{ref.current?.close();setOpen(false);router.refresh();}}>{children}</SavedContext.Provider>}</dialog></>;
}
