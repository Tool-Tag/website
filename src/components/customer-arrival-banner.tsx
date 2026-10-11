"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {customerRouteResponse,customerDeliveryAcknowledge} from "@/app/manual-audit-actions";
export function CustomerArrivalBanner({token,leg,responded}:{token:string;leg:"Pickup"|"Return";responded:boolean}){
 const [pending,start]=useTransition();const [error,setError]=useState("");const router=useRouter();
 return <aside className="customer-arrival-banner" role="status"><strong>Your driver is at your home — check the {leg==="Pickup"?"Pickup":"Delivery"} section below to let the driver know you’re on your way to the door.</strong><button disabled={pending||responded} onClick={()=>start(async()=>{const result=await customerRouteResponse(token,leg);setError(result.error??"");if(!result.error)router.refresh();})}>{responded?"Your driver knows you’re on your way":pending?"Sending…":"I'm on my way to the door"}</button>{error&&<p role="alert">{error}</p>}</aside>;
}
export function CustomerDeliveryAcknowledgment({token}:{token:string}){
 const [pending,start]=useTransition();const [error,setError]=useState("");const router=useRouter();
 return <section className="panel"><h2>Confirm receipt</h2><p>This confirms receipt of your items/work only. It is not a payment confirmation or a waiver of your rights.</p><button disabled={pending} onClick={()=>start(async()=>{const result=await customerDeliveryAcknowledge(token);setError(result.error??"");if(!result.error)router.refresh();})}>{pending?"Saving…":"I received my items/work"}</button>{error&&<p className="notice error" role="alert">{error}</p>}</section>;
}
