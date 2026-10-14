"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {pickupMissChoice} from "@/app/pickup-driver-actions";
import {PaymentForm} from "./payment-form";
import {RouteCalendar} from "./route-calendar";
import {denverDateTime} from "@/lib/domain/time";
import {money} from "@/lib/domain/money";
export type PickupRetry={chosen:boolean;paid:boolean;amount:number;date:string|null;expires_at:string|null;zelle:string;venmo:string};
export function PickupMissChoice({job,token,retry,cardConfigured=false}:{job:string;token:string;retry:PickupRetry;cardConfigured?:boolean}){
 const router=useRouter();const [pending,start]=useTransition();const [error,setError]=useState("");
 const choose=(choice:string)=>start(async()=>{const r=await pickupMissChoice(job,token,choice);if(r.error)setError(r.error);else router.refresh();});
 return <section className="panel"><h2>We missed your Pickup</h2><p>A new Pickup costs {money(retry.amount)}, including applicable tax. The original Pickup fee is nonrefundable because the driver arrived and received no response. Pay the new fee, then choose your next available Pickup date.</p>{retry.expires_at&&!retry.paid&&<p>Response deadline: {denverDateTime(retry.expires_at)}</p>}{!retry.chosen&&<button disabled={pending} onClick={()=>choose("reschedule")}>Reschedule Pickup · {money(retry.amount)}</button>}{retry.chosen&&!retry.paid&&<PaymentForm token={token} balanceDue={retry.amount} zelleEmail={retry.zelle} venmoHandle={retry.venmo} cardConfigured={cardConfigured} pickupRetryPayment/>}{retry.paid&&<><p>Your new Pickup fee is confirmed. Choose a date to send this pickup to the shop scheduling queue.</p><RouteCalendar job={job} leg="Pickup" token={token} locale="en" pickupRetry/></>}<button className="secondary" disabled={pending} onClick={()=>{if(window.confirm("Cancel this service? Your original Pickup fee will not be refunded."))choose("cancel");}}>Cancel service</button>{error&&<p role="alert">{error}</p>}</section>;
}
