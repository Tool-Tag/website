"use client";
import {useEffect,useRef} from "react";
import Link from "next/link";
import type {aggregateBands} from "@/lib/domain/urgent-attention";
export function LoginAttention({sessionId,bands}:{sessionId:string;bands:ReturnType<typeof aggregateBands>}){
 const ref=useRef<HTMLDialogElement>(null);
 useEffect(()=>{
  const key=`tooltag-login-attention:${sessionId}`;
  try{if(localStorage.getItem(key))return;localStorage.setItem(key,"shown");}catch{/* Storage may be disabled; show the pending summary. */}
  ref.current?.showModal();
 },[sessionId]);
 const total=bands.reduce((sum,band)=>sum+band.count,0);
 return <dialog ref={ref} className="login-attention" aria-labelledby="login-attention-title"><h2 id="login-attention-title">Pending attention</h2><p>Support, Refunds and Lost.</p>
 {bands.map(band=><section className={`urgency-band urgency-${band.color}`} key={band.color}><h3>{band.color.toUpperCase()} · {band.count} pending</h3><div className="urgency-categories">{band.categories.slice(0,3).map(category=><Link key={category.kind} href={category.href} onClick={()=>ref.current?.close()}>{category.count} {category.label}</Link>)}</div>{!band.count&&<p>No pending items.</p>}{band.categories.length>3&&<details><summary>See more</summary><div className="urgency-categories">{band.categories.slice(3).map(category=><Link key={category.kind} href={category.href} onClick={()=>ref.current?.close()}>{category.count} {category.label}</Link>)}</div></details>}</section>)}
 {!total&&<p>No pending attention items.</p>}<form method="dialog"><button>Continue</button></form></dialog>;
}
