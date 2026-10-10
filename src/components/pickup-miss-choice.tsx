"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {pickupMissChoice} from "@/app/pickup-driver-actions";
export function PickupMissChoice({job,token}:{job:string;token:string}){
 const router=useRouter();const [pending,start]=useTransition();const [error,setError]=useState("");
 const choose=(choice:string)=>start(async()=>{const r=await pickupMissChoice(job,token,choice);if(r.error)setError(r.error);else router.refresh();});
 return <section className="panel"><h2>We missed your Pickup</h2><p>Choose the next available Pickup day at no additional charge, or cancel your service. The original Pickup fee is nonrefundable in either case.</p><button disabled={pending} onClick={()=>choose("reschedule")}>Reschedule Pickup · $0</button><button className="secondary" disabled={pending} onClick={()=>{if(window.confirm("Cancel this service? Your Pickup fee will not be refunded."))choose("cancel");}}>Cancel service</button>{error&&<p role="alert">{error}</p>}</section>;
}
