"use client";
import {useEffect,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {pickupDriverAction} from "@/app/pickup-driver-actions";
export function PickupStopControls({stop,status,waitUntil,coming,blocked,hasEvidence,phone,nextStop}:{stop:string;status:string;waitUntil?:string|null;coming?:string|null;blocked:boolean;hasEvidence:boolean;phone?:string;nextStop?:string}){
 const router=useRouter();const [now,setNow]=useState(0);const [pending,start]=useTransition();const [error,setError]=useState("");
 useEffect(()=>{const tick=()=>setNow(Date.now());tick();const id=setInterval(tick,1000);return()=>clearInterval(id);},[]);
 useEffect(()=>{if(status==="Completed"||status==="Failed"){const next=sessionStorage.getItem("pickup-next-stop");if(next){document.getElementById(`pickup-stop-${next}`)?.scrollIntoView({behavior:"smooth",block:"start"});sessionStorage.removeItem("pickup-next-stop");}}},[status]);
 const left=waitUntil&&now?Math.max(0,Math.ceil((Date.parse(waitUntil)-now)/1000)):300;
 const count=`${Math.floor(left/60)}:${String(left%60).padStart(2,"0")}`;
 const run=(action:string)=>start(async()=>{setError("");const r=await pickupDriverAction(stop,action);if(r.error)setError(r.error);else {if(nextStop&&["picked-up","pickup-miss"].includes(action))sessionStorage.setItem("pickup-next-stop",nextStop);router.refresh();}});
 return <div className="pickup-controls">
 {blocked&&<p role="alert" className="notice error">Cancellation Requested / Production Hold. Pickup is blocked.</p>}
 {status==="Scheduled"&&<button disabled={pending||blocked} onClick={()=>run("en-route")}>Start · En Route</button>}
 {status==="En Route"&&<button disabled={pending||blocked} onClick={()=>run("arrived")}>Arrived</button>}
 {status==="Arrived"&&<>
 <button disabled={pending||blocked||!hasEvidence} onClick={()=>run("picked-up")}>Picked Up</button>
 {!hasEvidence&&<p className="muted">Add receiving photos before collecting this stop.</p>}
 <p className="pickup-timer" aria-live="off">{coming?"Customer is coming out":`Arrival wait · ${count}`}</p>
 <button className="secondary" disabled={pending||blocked||Boolean(coming)||left>0} onClick={()=>run("pickup-miss")}>Continue to next stop{!coming&&left>0?` · ${count}`:""}</button>
 {!coming&&left>0&&<button className="secondary" disabled={pending||blocked} onClick={()=>run("customer-coming")}>Customer said they are coming out</button>}
 {(left===0||coming)&&<button className="secondary" disabled={pending||blocked} onClick={()=>run("wait-more")}>Wait more · 5 minutes</button>}
 {!coming&&left===0&&phone&&<a className="button secondary" href={`sms:${phone.replace(/[^+0-9]/g,"")}?body=${encodeURIComponent("ToolTag has arrived for your Pickup. Please come out with your items.")}`}>Send text message</a>}
 </>}
 {status==="Completed"&&<p className="notice success">Picked Up</p>}
 {status==="Failed"&&<p className="notice">Pickup missed. Customer can reschedule or cancel.</p>}
 {error&&<p role="alert" className="notice error">{error}</p>}
 </div>;
}
