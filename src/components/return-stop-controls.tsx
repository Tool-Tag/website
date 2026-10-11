"use client";
import {driverLocation} from "@/lib/domain/driver-location";
import {useEffect,useState,useTransition} from "react";
import {denverDateTime} from "@/lib/domain/time";
import {useRouter} from "next/navigation";
import {returnDriverAction} from "@/app/return-driver-actions";
export function ReturnStopControls({stop,status,waitUntil,coming,blocked,hasEvidence,phone,nextStop,cash,balance,address,retryExpires}:{stop:string;status:string;waitUntil?:string|null;coming?:string|null;blocked:boolean;hasEvidence:boolean;phone?:string;nextStop?:string;cash:boolean;balance:number;address?:string;retryExpires?:string|null}){
 const router=useRouter();const [now,setNow]=useState(0);const [pending,start]=useTransition();const [error,setError]=useState("");const [present,setPresent]=useState(false);
 useEffect(()=>{const tick=()=>setNow(Date.now());tick();const id=setInterval(tick,1000);return()=>clearInterval(id);},[]);
 useEffect(()=>{if(status==="Completed"||status==="Failed"){const next=sessionStorage.getItem("return-next-stop");if(next){document.getElementById(`return-stop-${next}`)?.scrollIntoView({behavior:"smooth",block:"start"});sessionStorage.removeItem("return-next-stop");}}},[status]);
 const left=waitUntil&&now?Math.max(0,Math.ceil((Date.parse(waitUntil)-now)/1000)):300;const count=`${Math.floor(left/60)}:${String(left%60).padStart(2,"0")}`;
 const run=(action:string)=>start(async()=>{setError("");const r=await returnDriverAction(stop,action,present,driverLocation());if(r.error)setError(r.error);else {if(nextStop&&["delivered","not-home"].includes(action))sessionStorage.setItem("return-next-stop",nextStop);router.refresh();}});
 return <div className="pickup-controls">
 <label className="checkbox"><input type="checkbox" />Start recording before exiting the vehicle</label>
 <p className="notice">Customer must be present. Never leave items at the door, even when fully paid.</p>
 {blocked&&<p role="alert" className="notice error">Delivery blocked: route paused, pending additional work or Cancellation Requested / Production Hold.</p>}
 {status==="Requested"&&<p className="notice">Provisional reservation · Pending. The second-attempt fee must be paid and verified before this stop can start. Items stay at the shop. {retryExpires&&`Reservation expires ${denverDateTime(retryExpires)} or at the route payment cutoff.`}</p>}
 {status==="Scheduled"&&<button disabled={pending||blocked} onClick={()=>{const map=address?window.open("about:blank","_blank"):null;if(map)map.opener=null;start(async()=>{const result=await returnDriverAction(stop,"en-route",present,driverLocation());if(result.error){setError(result.error);map?.close();}else{if(map&&address)map.location.href=`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;router.refresh();}});}}>Ir</button>}
 {status==="En Route"&&<button disabled={pending||blocked} onClick={()=>run("arrived")}>Arrived</button>}
 {status==="Arrived"&&<>
 <label className="checkbox"><input type="checkbox" checked={present} onChange={e=>setPresent(e.target.checked)} />Customer is here to receive the items</label>
 {cash&&balance>0&&<button disabled={pending||blocked||!present} onClick={()=>{if(window.confirm("Confirm that you have received the cash payment in full?"))run("cash");}}>Pago recibido · ${balance.toFixed(2)}</button>}
 <button disabled={pending||blocked||!hasEvidence||!present||balance>0} onClick={()=>run("delivered")}>Delivered</button>
 {!hasEvidence&&<p className="muted">Add Delivery Evidence photos before confirming delivery.</p>}{balance>0&&<p className="notice">Payment required before handover.</p>}
 <p className="pickup-timer">{coming?"Customer is coming out":`Arrival wait · ${count}`}</p>
 <button className="secondary" disabled={pending||blocked||Boolean(coming)||present||left>0} onClick={()=>run("not-home")}>Continue to next stop{!coming&&left>0?` · ${count}`:""}</button>
 {!coming&&<button className="secondary" disabled={pending||blocked} onClick={()=>run("customer-coming")}>Customer said they are coming out</button>}
 {!coming&&left===0&&phone&&<a className="button secondary" href={`tel:${phone.replace(/[^+0-9]/g,"")}`}>Call customer · optional</a>}
 </>}
 {status==="Completed"&&<p className="notice success">Delivered</p>}
 {status==="Failed"&&<p className="notice">Delivery pending. Nothing was left unattended.</p>}
 {error&&<p role="alert" className="notice error">{error}</p>}
 </div>;
}
