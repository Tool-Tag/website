"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {lostCustomerChoice} from "@/app/lost-actions";
import type {LostChoice} from "@/lib/domain/lost-flow";
export function LostResolutionChoice({token}:{token:string}) {
 const [choice,setChoice]=useState<LostChoice|null>(null),[error,setError]=useState("");const [pending,start]=useTransition();const router=useRouter();
 return <><p>Choose replacement of the missing items or a monetary refund at the market value shown above.</p><fieldset disabled={pending}><legend>Preferred resolution</legend>{(["Replace Item","Refund money"] as const).map(option=><label className="checkbox" key={option}><input type="radio" name="resolution" checked={choice===option} onChange={()=>setChoice(option)}/>{option}</label>)}</fieldset><button type="button" disabled={!choice||pending} onClick={()=>{if(!choice)return;setError("");start(async()=>{const result=await lostCustomerChoice(token,choice);if(result.error)setError(result.error);else router.refresh();});}}>{pending?"Saving…":"Confirm my choice"}</button>{error&&<p role="alert" className="notice error">{error}</p>}</>;
}
