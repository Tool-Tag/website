"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {driverLossOwnerDecision} from "@/app/driver-loss-actions";
export function DriverLossOwnerControls({driver}:{driver:string}){
 const [reason,setReason]=useState(""),[error,setError]=useState("");const [pending,start]=useTransition();const router=useRouter();
 function decide(action:"allow"|"ban"){if(action==="ban"&&!window.confirm("Confirm the driver ban based on documented noncompliance?"))return;start(async()=>{const result=await driverLossOwnerDecision(driver,action,reason);if(result.error)setError(result.error);else{setReason("");setError("");router.refresh();}});}
 return <section><h3>Owner driver decision</h3><p>Only Owner can authorize continued eligibility after the first warning or confirm a ban/noncompliance. No money is deducted or collected here.</p><label>Decision reason<textarea maxLength={2000} value={reason} disabled={pending} onChange={e=>setReason(e.target.value)}/></label><div className="actions"><button type="button" disabled={pending||!reason.trim()} onClick={()=>decide("allow")}>Allow new assignments</button><button type="button" className="secondary" disabled={pending||!reason.trim()} onClick={()=>decide("ban")}>Record ban / noncompliance</button></div>{error&&<p role="alert" className="notice error">{error}</p>}</section>;
}
