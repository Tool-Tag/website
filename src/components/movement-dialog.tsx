"use client";
import {useId,useRef,useState} from "react";
import {useRouter} from "next/navigation";
import {MovementForm} from "./movement-form";
import {DialogClose} from "./dialog-close";
export function MovementDialog(props:Parameters<typeof MovementForm>[0]) {
 const [open,setOpen]=useState(false);
 const ref=useRef<HTMLDialogElement>(null),id=useId(),router=useRouter();
 return <><button type="button" className="menu-link-blue-electric" onClick={()=>{setOpen(true);ref.current?.showModal();}}>+ Record Transaction</button>
 <dialog ref={ref} className="action-modal" aria-labelledby={id} onClose={()=>setOpen(false)}><DialogClose/><h2 id={id}>Record Transaction</h2>
 {open&&<MovementForm {...props} onSaved={(result)=>{ref.current?.close();const saved=result as {type?:string;id?:unknown};if(saved?.type==="EXPENSE"&&typeof saved.id==="string")router.push(`/app/finance/expenses?created=${encodeURIComponent(saved.id)}`);router.refresh();}}/>}
 </dialog></>;
}
