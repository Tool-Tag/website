"use client";
import {useState,useTransition} from "react";
import {acknowledgeRefund} from "@/app/refund-actions-public";
import {useRouter} from "next/navigation";
export function RefundAcknowledgment({token}:{token:string}){const [error,setError]=useState(""),[pending,start]=useTransition(),router=useRouter();return <><button disabled={pending} onClick={()=>start(async()=>{const result=await acknowledgeRefund(token);setError(result.error||"");router.refresh();})}>{pending?"Confirming…":"Confirm Receipt"}</button>{error&&<p role="alert">{error}</p>}</>;}
