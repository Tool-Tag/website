"use client";
import {useEffect,useRef} from "react";
import Link from "next/link";
import {attentionBands,type UrgentItem} from "@/lib/domain/urgent-attention";
export function LoginAttention({sessionId,items}:{sessionId:string;items:UrgentItem[]}){
 const ref=useRef<HTMLDialogElement>(null);
 useEffect(()=>{
  const key=`tooltag-login-attention:${sessionId}`;
  try{if(localStorage.getItem(key))return;localStorage.setItem(key,"shown");}catch{/* Storage may be disabled; show the pending summary. */}
  ref.current?.showModal();
 },[sessionId]);
 return <dialog ref={ref} className="login-attention" aria-labelledby="login-attention-title"><h2 id="login-attention-title">Pending attention</h2><p>Refunds, customer responses and Lost cases.</p>
 {attentionBands(items).map(band=><section className={`urgency-band urgency-${band.color}`} key={band.color}><h3>{band.color.toUpperCase()} · {band.items.length} pending</h3><p>{band.items.filter(i=>i.kind==="refund").length} refunds · {band.items.filter(i=>i.kind==="problem").length} customer responses · {band.items.filter(i=>i.kind==="lost").length} Lost cases</p>{band.items.length>0&&<ul>{band.items.map(item=><li key={`${item.kind}:${item.id}`}><Link href={item.href} onClick={()=>ref.current?.close()}>{item.label}</Link> · {item.kind==="lost"?"Lost":`${item.kind==="refund"?"Refund":"Response"} · day ${item.days}`}</li>)}</ul>}</section>)}
 {!items.length&&<p>No pending attention items.</p>}<form method="dialog"><button>Continue</button></form></dialog>;
}
