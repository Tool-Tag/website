"use client";
import {HexModalFrame,ModalActions} from "./hex-modal-frame";

import {useRef,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {DialogClose} from "./dialog-close";
import {acceptDriverBlock} from "@/app/driver-block-actions";
import {denverDateTime} from "@/lib/domain/time";
export type BlockAgreement={key:string;accepted:boolean;accepted_at?:string;can_accept:boolean;snapshot:{revision:string;route_id:string;route_date:string;leg:string;block_number:number;driver_name:string;route_start:string;block_start:string;policies:[string,string][];terms:[string,string][];stops:{id:string;job:string;sequence:number}[]}};
export function DriverBlockAgreement({agreement}:{agreement:BlockAgreement}){
 const dialog=useRef<HTMLDialogElement>(null),router=useRouter();const [insurance,setInsurance]=useState("");const [registration,setRegistration]=useState("");const [consent,setConsent]=useState(false);const [error,setError]=useState("");const [pending,start]=useTransition();const s=agreement.snapshot;
 return <section className="notice"><strong>Block acceptance agreement</strong><p>{agreement.accepted?`Accepted ${denverDateTime(agreement.accepted_at)}`:agreement.can_accept?"Review and accept this block before leaving the shop.":"The assigned driver must confirm at least two hours before the route. Contact ToolTag if the deadline has passed."}</p><button type="button" className="menu-link-blue-electric" onClick={()=>dialog.current?.showModal()}>Review block agreement</button>
 <dialog ref={dialog} className="hex-dialog action-modal" aria-label="Block acceptance agreement"><HexModalFrame><DialogClose/><h2>{s.leg} · {s.route_date}</h2><p>Block {s.block_number} · Driver: {s.driver_name}<br/><small>Reference: {s.route_id}</small></p><p>At the shop: {denverDateTime(s.block_start)}<br/>Route starts: {denverDateTime(s.route_start)}</p><p>{s.stops.length} stops: {s.stops.map(x=>x.job).join(", ")}</p>
 {[...s.policies,...s.terms].map(([title,text])=><section key={title}><h3>{title}</h3><p>{text}</p></section>)}<p>Agreement Rev: {s.revision}<br/>ToolTag - Bandits of the Framing LLC</p>
 {!agreement.accepted&&agreement.can_accept&&<form onSubmit={e=>{e.preventDefault();if(!consent)return;start(async()=>{const result=await acceptDriverBlock(s.route_id,agreement.key,insurance,registration);setError(result.error??"");if(!result.error){dialog.current?.close();router.refresh();}});}}><label>Vehicle insurance valid through<input type="date" min={s.route_date} required value={insurance} onChange={e=>setInsurance(e.target.value)}/></label><label>Vehicle registration valid through<input type="date" min={s.route_date} required value={registration} onChange={e=>setRegistration(e.target.value)}/></label><label><input type="checkbox" checked={consent} onChange={e=>setConsent(e.target.checked)}/>I accept this block agreement and confirm that my vehicle insurance is active and my registration is current.</label><ModalActions><button className="menu-link-blue-electric" disabled={pending||!consent}>Accept and confirm block</button></ModalActions>{error&&<p role="alert">{error}</p>}</form>}
 </HexModalFrame></dialog></section>;
}
