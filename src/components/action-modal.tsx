"use client";
import {HexModalFrame} from "./hex-modal-frame";

import {createContext,useContext,useId,useRef,useState,type ReactNode} from "react";
import {useRouter} from "next/navigation";
import {DialogClose} from "./dialog-close";
const SavedContext=createContext<(()=>void)|null>(null);
export const useActionModal=()=>useContext(SavedContext);
export function ActionModal({title,label,children,trigger,triggerClassName,kicker}:{title:string;label:string;children:ReactNode;trigger?:ReactNode;triggerClassName?:string;kicker?:string}) {
 const ref=useRef<HTMLDialogElement>(null),id=useId(),router=useRouter(),[open,setOpen]=useState(false);
 return <><button type="button" className={triggerClassName??"menu-link-blue-electric"} onClick={()=>{setOpen(true);ref.current?.showModal();}}>{trigger??label}</button>
 <dialog ref={ref} className="hex-dialog action-modal" aria-labelledby={id} onClose={()=>setOpen(false)}><HexModalFrame><DialogClose/>{kicker?<header><p className="eyebrow">{kicker}</p><h2 id={id}>{title}</h2></header>:<h2 id={id}>{title}</h2>}
 {open&&<SavedContext.Provider value={()=>{ref.current?.close();setOpen(false);router.refresh();}}>{children}</SavedContext.Provider>}</HexModalFrame></dialog></>;
}
