"use client";
import {HexModalFrame} from "./hex-modal-frame";

import {ModalClose} from "./modal-close";
import {useEffect,useId,useRef} from "react";
import {AssetForm} from "./asset-form";
import {money} from "@/lib/domain/money";

export function EquipmentRegistrationModal({expense,categories}:{expense:{id:string;description:string;amount:string;vendor:string;date:string};categories:{value:string;label:string}[]}) {
  const dialog=useRef<HTMLDialogElement>(null),title=useId();
  useEffect(()=>{if(dialog.current&&!dialog.current.open)dialog.current.showModal();},[expense.id]);
  return <>
    <div className="notice success">Equipment purchase saved. <button className="secondary" type="button" onClick={()=>dialog.current?.showModal()}>Register equipment</button></div>
    <dialog ref={dialog} className="hex-dialog equipment-registration-modal" aria-labelledby={title}><HexModalFrame>
      <header className="pagehead"><h2 id={title}>Register Equipment</h2><ModalClose className="secondary modal-close" type="button" onClick={()=>dialog.current?.close()} aria-label="Close dialog">×</ModalClose></header>
      <p>{expense.description} · {money(expense.amount)}</p>
      <p className="muted">{expense.vendor} · {expense.date}</p>
      <p>The purchase is already saved in Finance. This registration links the equipment to that expense without creating another charge.</p>
      {categories.length?<AssetForm categories={categories} expenses={[{value:expense.id,label:expense.description}]} expense={expense.id} lockedExpense defaultName={expense.description} back="/app/finance/expenses"/>:<p role="alert">Add an active Equipment category in Settings before registering this item. Your expense is already saved.</p>}
    </HexModalFrame></dialog>
  </>;
}
