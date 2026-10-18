"use client";
import {ModalClose} from "./modal-close";
import { useRef, type ReactNode } from "react";

export function ShopReceivingModal({job,customer,count,children}:{job:string;customer:string;count:number;children:ReactNode}) {
 const dialog=useRef<HTMLDialogElement>(null);
 return <>
  <button type="button" className="shop-receiving-row blue-electric" aria-haspopup="dialog" onClick={()=>dialog.current?.showModal()}>
   <strong>{job}</strong><span>{customer}</span><span>{count} {count===1?"piece":"pieces"} awaiting verification</span><span aria-hidden="true">↗</span>
  </button>
  <dialog ref={dialog} className="shop-receiving-modal" aria-label={`Receiving verification: ${job}`}>
   <header className="actions" style={{justifyContent:"space-between"}}><div><h2>{job}</h2><p>{customer}</p></div><ModalClose type="button" className="secondary modal-close" onClick={()=>dialog.current?.close()} aria-label="Close dialog">×</ModalClose></header>
   {children}
  </dialog>
 </>;
}
