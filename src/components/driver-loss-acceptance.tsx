"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {acceptDriverLossAgreement} from "@/app/driver-loss-actions";
export function DriverLossAcceptance({id}:{id:string}){
 const [checked,setChecked]=useState(false),[error,setError]=useState("");const [pending,start]=useTransition();const router=useRouter();
 return <><label className="checkbox"><input type="checkbox" checked={checked} disabled={pending} onChange={e=>setChecked(e.target.checked)}/>I have read and accept this exact agreement version.</label><button type="button" disabled={pending||!checked} onClick={()=>start(async()=>{const result=await acceptDriverLossAgreement(id);if(result.error)setError(result.error);else router.refresh();})}>{pending?"Saving…":"Accept agreement"}</button>{error&&<p role="alert" className="notice error">{error}</p>}</>;
}
